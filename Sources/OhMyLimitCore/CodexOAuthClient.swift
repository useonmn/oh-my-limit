import CryptoKit
import Foundation
import Security

/// ChatGPT OAuth login for Codex accounts, without the codex CLI.
/// Mirrors the CLI's own flow: PKCE + a loopback callback on the registered
/// ports, token exchange at the issuer, refresh with the refresh token.
public struct CodexOAuthClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let issuer: String
    private let clientID: String
    private let transport: Transport

    public init(issuer: String = CodexOAuthConfiguration.issuer,
                clientID: String = CodexOAuthConfiguration.clientID) {
        self.init(issuer: issuer, clientID: clientID, transport: CodexOAuthHTTPS.send)
    }

    init(issuer: String, clientID: String, transport: @escaping Transport) {
        self.issuer = issuer
        self.clientID = clientID
        self.transport = transport
    }

    /// Runs the browser login: opens the authorize URL via `onURL`, waits for
    /// the loopback callback, exchanges the code, and returns credentials.
    public func login(onURL: @escaping @Sendable (URL) -> Void) async throws -> CodexOAuthCredentials {
        try Task.checkCancellation()
        let state = Self.randomURLSafe(byteCount: 32)
        let verifier = Self.randomURLSafe(byteCount: 32)
        let challenge = Self.codeChallenge(verifier: verifier)
        let callback = try AntigravityOAuthCallback(
            state: state,
            ports: CodexOAuthConfiguration.callbackPorts,
            path: CodexOAuthConfiguration.callbackPath,
            redirectHost: "localhost"
        )
        let code = try await callback.wait { redirect in
            guard let url = Self.authorizeURL(
                issuer: self.issuer, clientID: self.clientID,
                redirect: redirect, state: state, challenge: challenge
            ) else { return }
            onURL(url)
        }
        guard let redirect = await callback.redirectURI() else { throw CodexOAuthError.callbackUnavailable }
        try Task.checkCancellation()
        return try await exchange(code: code, redirect: redirect, verifier: verifier)
    }

    /// Exchanges a still-valid refresh token for fresh credentials.
    public func refresh(_ credentials: CodexOAuthCredentials) async throws -> CodexOAuthCredentials {
        let tokens = try await tokenRequest([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", credentials.refreshToken)
        ])
        return try Self.credentials(from: tokens, previous: credentials)
    }

    private func exchange(code: String, redirect: URL, verifier: String) async throws -> CodexOAuthCredentials {
        let tokens = try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("redirect_uri", redirect.absoluteString),
            ("code_verifier", verifier)
        ])
        return try Self.credentials(from: tokens, previous: nil)
    }

    static func authorizeURL(issuer: String, clientID: String, redirect: URL,
                             state: String, challenge: String) -> URL? {
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: CodexOAuthConfiguration.scope),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: CodexOAuthConfiguration.originator)
        ]
        return components?.url
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
    }

    private func tokenRequest(_ parameters: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "\(issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = parameters
            .map { "\($0.0)=\(Self.formEscape($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let data = try await send(request)
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !tokens.access_token.isEmpty else { throw CodexOAuthError.invalidResponse }
        return tokens
    }

    private func send(_ input: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport(input)
            try Task.checkCancellation()
            guard data.count <= 65_536 else { throw CodexOAuthError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                if response.statusCode == 400 { throw CodexOAuthError.signInRequired }
                throw CodexOAuthError.authorizationFailed(response.statusCode)
            }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? CodexOAuthError { throw error }
            if (error as? URLError)?.code == .timedOut { throw CodexOAuthError.timedOut }
            throw CodexOAuthError.networkFailure
        }
    }

    static func credentials(from tokens: TokenResponse, previous: CodexOAuthCredentials?) throws -> CodexOAuthCredentials {
        let claims = tokens.id_token.flatMap(jwtClaims)
        let email = claims?.email ?? previous?.email ?? ""
        let accountID = claims?.accountID ?? previous?.accountID ?? ""
        guard !email.isEmpty, !accountID.isEmpty else { throw CodexOAuthError.invalidResponse }
        guard let refreshToken = tokens.refresh_token ?? previous?.refreshToken,
              !refreshToken.isEmpty else { throw CodexOAuthError.invalidResponse }
        let expiresAt = Date().addingTimeInterval(tokens.expires_in ?? 3600)
        return CodexOAuthCredentials(
            accessToken: tokens.access_token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountID: accountID,
            email: email,
            planType: claims?.planType ?? previous?.planType
        )
    }

    struct JWTClaims {
        let email: String?
        let accountID: String?
        let planType: String?
    }

    static func jwtClaims(_ jwt: String) -> JWTClaims? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        return JWTClaims(
            email: json["email"] as? String,
            accountID: auth?["chatgpt_account_id"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String
        )
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func codeChallenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
        ) ?? value
    }

    static func valid(_ credentials: CodexOAuthCredentials) -> Bool {
        !credentials.accessToken.isEmpty && !credentials.refreshToken.isEmpty
            && !credentials.accountID.isEmpty && !credentials.email.isEmpty
    }
}

/// One ephemeral session per request; redirect targets never receive credentials.
final class CodexOAuthHTTPS: NSObject, URLSessionTaskDelegate, Sendable {
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: CodexOAuthHTTPS(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 65_536 else {
            throw CodexOAuthError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw CodexOAuthError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completion(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
