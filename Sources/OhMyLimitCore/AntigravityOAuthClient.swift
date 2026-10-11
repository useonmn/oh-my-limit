import Foundation

public struct AntigravityOAuthClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let configuration: AntigravityOAuthConfiguration
    private let transport: Transport

    public init(configuration: AntigravityOAuthConfiguration = .standard) {
        self.init(configuration: configuration, transport: AntigravityOAuthHTTPS.send)
    }

    init(configuration: AntigravityOAuthConfiguration, transport: @escaping Transport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func login(onURL: @escaping @Sendable (URL) -> Void) async throws -> AntigravityOAuthCredentials {
        try Task.checkCancellation()
        let state = try OAuthPKCE.randomURLSafe()
        let verifier = try OAuthPKCE.randomURLSafe()
        let callback = try AntigravityOAuthCallback(state: state)
        let code = try await callback.wait { redirectURI in
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: AntigravityOAuthConfiguration.scopes.joined(separator: " ")),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: OAuthPKCE.challenge(verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
            onURL(url.url!)
        }
        guard let redirectURI = await callback.redirectURI() else { throw AntigravityOAuthError.callbackUnavailable }
        return try await exchange(code: code, redirectURI: redirectURI, verifier: verifier)
    }

    public func refresh(_ credentials: AntigravityOAuthCredentials) async throws -> AntigravityOAuthCredentials {
        guard Self.valid(credentials) else { throw AntigravityOAuthError.invalidResponse }
        return try await tokens(fields: ["grant_type": "refresh_token", "refresh_token": credentials.refreshToken], previous: credentials)
    }

    func exchange(code: String, redirectURI: URL, verifier: String) async throws -> AntigravityOAuthCredentials {
        try await tokens(fields: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI.absoluteString, "code_verifier": verifier
        ], previous: nil)
    }

    private func tokens(fields: [String: String], previous: AntigravityOAuthCredentials?) async throws -> AntigravityOAuthCredentials {
        var fields = fields
        fields["client_id"] = configuration.clientID
        fields["client_secret"] = configuration.clientSecret
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        // Start expiry before the network round trip, never overestimating the token's lifetime.
        let issuedAt = Date()
        let data = try await send(request)
        struct Token: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
            let token_type: String
        }
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              token.token_type.lowercased() == "bearer", Self.validToken(token.access_token),
              token.expires_in.isFinite, token.expires_in > 0, token.expires_in <= 31_536_000,
              let refreshToken = token.refresh_token ?? previous?.refreshToken, Self.validToken(refreshToken)
        else { throw AntigravityOAuthError.invalidResponse }

        var identityRequest = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        identityRequest.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
        let identityData = try await send(identityRequest)
        struct Userinfo: Decodable { let id: String; let email: String }
        guard let identity = try? JSONDecoder().decode(Userinfo.self, from: identityData),
              Self.validIdentity(identity.id, limit: 512), Self.validIdentity(identity.email, limit: 320),
              previous == nil || previous?.accountID == identity.id
        else { throw AntigravityOAuthError.invalidResponse }
        return AntigravityOAuthCredentials(
            accessToken: token.access_token, refreshToken: refreshToken,
            expiresAt: issuedAt.addingTimeInterval(token.expires_in), accountID: identity.id, email: identity.email
        )
    }

    private func send(_ input: URLRequest) async throws -> Data {
        var request = input
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard data.count <= 65_536, response.expectedContentLength <= 65_536 else { throw AntigravityOAuthError.invalidResponse }
            guard response.statusCode == 200 else {
                struct Failure: Decodable { let error: String }
                if response.statusCode == 400,
                   (try? JSONDecoder().decode(Failure.self, from: data).error) == "invalid_grant" {
                    throw AntigravityOAuthError.signInRequired
                }
                throw AntigravityOAuthError.authorizationFailed(response.statusCode)
            }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? AntigravityOAuthError { throw error }
            if (error as? URLError)?.code == .timedOut { throw AntigravityOAuthError.timedOut }
            throw AntigravityOAuthError.networkFailure
        }
    }

    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    static func valid(_ credentials: AntigravityOAuthCredentials) -> Bool {
        validToken(credentials.accessToken) && validToken(credentials.refreshToken)
            && credentials.expiresAt.timeIntervalSince1970.isFinite
            && validIdentity(credentials.accountID, limit: 512) && validIdentity(credentials.email, limit: 320)
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func validIdentity(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum AntigravityOAuthHTTPS {
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OAuthHTTPS.send(request, invalidResponse: AntigravityOAuthError.invalidResponse)
    }
}
