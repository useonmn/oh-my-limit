import Foundation
import LocalAuthentication
import Security

/// Public installed-app client configuration used by Claude Code's claude.ai login.
/// This app requests only `user:profile`, the scope the usage endpoint needs, so its
/// tokens cannot run inference. Its grant is separate from Claude Code's: refreshing
/// it never rotates or invalidates Claude Code's own login.
public enum ClaudeOAuthConfiguration {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    public static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    public static let scope = "user:profile"
    public static let callbackPath = "/callback"
}

public struct ClaudeOAuthCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String
    public let email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
    }

    public var identity: CodexIdentity { CodexIdentity(email: email, accountID: accountID) }
}

public enum ClaudeOAuthError: Error, LocalizedError, Equatable, Sendable {
    case signInRequired
    case userCancelled
    case timedOut
    case callbackUnavailable
    case invalidResponse
    case networkFailure
    case authorizationFailed(Int)
    case storageFailure(Int32)

    var needsKeychainAccess: Bool {
        guard case .storageFailure(let status) = self else { return false }
        return status == errSecInteractionNotAllowed || status == errSecInteractionRequired
            || status == errSecAuthFailed || status == errSecUserCanceled
    }

    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Claude 계정에 다시 로그인해 주세요."
        case .userCancelled: "Claude 로그인을 취소했습니다."
        case .timedOut: "Claude 로그인 또는 조회 시간이 초과되었습니다. 다시 시도해 주세요."
        case .callbackUnavailable: "Claude 로그인 응답을 받을 수 없습니다. 다시 시도해 주세요."
        case .invalidResponse: "Claude 인증 응답을 확인할 수 없습니다."
        case .networkFailure: "Anthropic 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요."
        case .authorizationFailed(let status): "Claude 인증 요청에 실패했습니다 (HTTP \(status))."
        case .storageFailure where needsKeychainAccess:
            "키체인 접근 권한이 필요합니다. 키체인 접근 허용 버튼을 눌러 Oh My Limit의 접근을 허용해 주세요. 키체인이 잠겨 있다면 먼저 잠금을 해제해 주세요."
        case .storageFailure(let status): "로그인 정보를 키체인에 저장하거나 읽지 못했습니다 (코드 \(status))."
        }
    }
}

public struct ClaudeOAuthClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    public init() {
        self.init(transport: CodexOAuthHTTPS.send)
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    public func login(onURL: @escaping @Sendable (URL) -> Void) async throws -> ClaudeOAuthCredentials {
        try Task.checkCancellation()
        let state = CodexOAuthClient.randomURLSafe(byteCount: 32)
        let verifier = CodexOAuthClient.randomURLSafe(byteCount: 32)
        let challenge = CodexOAuthClient.codeChallenge(verifier: verifier)
        let callback: AntigravityOAuthCallback
        do {
            callback = try AntigravityOAuthCallback(
                state: state, path: ClaudeOAuthConfiguration.callbackPath, redirectHost: "localhost"
            )
        } catch { throw ClaudeOAuthError.callbackUnavailable }
        let code: String
        do {
            code = try await callback.wait { redirect in
                guard let url = Self.authorizeURL(redirect: redirect, state: state, challenge: challenge) else { return }
                onURL(url)
            }
        } catch let error as AntigravityOAuthError {
            switch error {
            case .userCancelled: throw ClaudeOAuthError.userCancelled
            case .timedOut: throw ClaudeOAuthError.timedOut
            case .invalidResponse: throw ClaudeOAuthError.invalidResponse
            default: throw ClaudeOAuthError.callbackUnavailable
            }
        }
        guard let redirect = await callback.redirectURI() else { throw ClaudeOAuthError.callbackUnavailable }
        try Task.checkCancellation()
        let issuedAt = Date()
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": ClaudeOAuthConfiguration.clientID,
            "code": code,
            "redirect_uri": redirect.absoluteString,
            "code_verifier": verifier,
            "state": state
        ])
        return try Self.credentials(from: tokens, previous: nil, issuedAt: issuedAt)
    }

    public func refresh(_ credentials: ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials {
        let issuedAt = Date()
        let tokens = try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": ClaudeOAuthConfiguration.clientID,
            "refresh_token": credentials.refreshToken,
            "scope": ClaudeOAuthConfiguration.scope
        ])
        return try Self.credentials(from: tokens, previous: credentials, issuedAt: issuedAt)
    }

    static func authorizeURL(redirect: URL, state: String, challenge: String) -> URL? {
        var components = URLComponents(string: ClaudeOAuthConfiguration.authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeOAuthConfiguration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "scope", value: ClaudeOAuthConfiguration.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    struct TokenResponse: Decodable {
        struct Account: Decodable {
            let uuid: String
            let email_address: String?
        }
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let account: Account?
    }

    static func credentials(from tokens: TokenResponse, previous: ClaudeOAuthCredentials?,
                            issuedAt: Date) throws -> ClaudeOAuthCredentials {
        guard validToken(tokens.access_token), tokens.expires_in.isFinite,
              tokens.expires_in > 0, tokens.expires_in <= 31_536_000,
              let refreshToken = tokens.refresh_token ?? previous?.refreshToken, validToken(refreshToken),
              let accountID = tokens.account?.uuid ?? previous?.accountID, !accountID.isEmpty,
              let email = tokens.account?.email_address ?? previous?.email, !email.isEmpty,
              // A refresh must never silently switch the account this profile belongs to.
              previous == nil || previous?.accountID == accountID
        else { throw ClaudeOAuthError.invalidResponse }
        return ClaudeOAuthCredentials(
            accessToken: tokens.access_token, refreshToken: refreshToken,
            // Start expiry before the network round trip, never overestimating the lifetime.
            expiresAt: issuedAt.addingTimeInterval(tokens.expires_in), accountID: accountID, email: email
        )
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: ClaudeOAuthConfiguration.tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let data: Data
        do {
            try Task.checkCancellation()
            let (body, response) = try await transport(request)
            try Task.checkCancellation()
            guard body.count <= 65_536 else { throw ClaudeOAuthError.invalidResponse }
            guard response.statusCode == 200 else {
                if response.statusCode == 400 || response.statusCode == 401 { throw ClaudeOAuthError.signInRequired }
                throw ClaudeOAuthError.authorizationFailed(response.statusCode)
            }
            data = body
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? ClaudeOAuthError { throw error }
            if (error as? URLError)?.code == .timedOut { throw ClaudeOAuthError.timedOut }
            throw ClaudeOAuthError.networkFailure
        }
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ClaudeOAuthError.invalidResponse
        }
        return tokens
    }

    static func valid(_ credentials: ClaudeOAuthCredentials) -> Bool {
        validToken(credentials.accessToken) && validToken(credentials.refreshToken)
            && credentials.expiresAt.timeIntervalSince1970.isFinite
            && !credentials.accountID.isEmpty && !credentials.email.isEmpty
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

/// Keychain persistence for this app's own Claude credentials. Claude Code's
/// Keychain item and credential file are never read or written here.
public struct ClaudeOAuthKeychain: Sendable {
    private let service: String
    private let security: any AntigravityOAuthSecurity

    public init(service: String = "local.ohmylimit.claude.oauth") {
        self.init(service: service, security: OAuthSystemSecurity())
    }

    init(service: String, security: any AntigravityOAuthSecurity) {
        self.service = service
        self.security = security
    }

    public func load(profileID: UUID, allowInteraction: Bool = false) throws -> ClaudeOAuthCredentials? {
        var query = query(profileID: profileID, allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data, data.count <= 65_536,
                  let credentials = try? JSONDecoder().decode(ClaudeOAuthCredentials.self, from: data),
                  ClaudeOAuthClient.valid(credentials) else { return nil }
            return credentials
        case errSecItemNotFound: return nil
        default: throw ClaudeOAuthError.storageFailure(status)
        }
    }

    public func save(_ credentials: ClaudeOAuthCredentials, profileID: UUID, allowInteraction: Bool = false) throws {
        guard ClaudeOAuthClient.valid(credentials),
              let data = try? JSONEncoder().encode(credentials) else { throw ClaudeOAuthError.invalidResponse }
        let query = query(profileID: profileID, allowInteraction: allowInteraction)
        // Update in place: a failed save must not first destroy a working refresh token.
        var status = security.update(query, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            status = security.add(attributes)
            // Another instance may have added this same profile between update and add.
            if status == errSecDuplicateItem {
                status = security.update(query, attributes: [kSecValueData as String: data])
            }
        }
        guard status == errSecSuccess else { throw ClaudeOAuthError.storageFailure(status) }
    }

    public func remove(profileID: UUID, allowInteraction: Bool = false) throws {
        let status = security.delete(query(profileID: profileID, allowInteraction: allowInteraction))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeOAuthError.storageFailure(status)
        }
    }

    private func query(profileID: UUID, allowInteraction: Bool) -> [String: Any] {
        // This non-sandboxed macOS app uses the login Keychain.
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false,
            kSecUseAuthenticationContext as String: context
        ]
    }
}

/// Owns this app's Claude credentials only; direct accounts never fall back to Claude Code's login.
public struct ClaudeDirectClient: Sendable {
    private let keychain: ClaudeOAuthKeychain
    private let authenticate: @Sendable (@escaping @Sendable (URL) -> Void) async throws -> ClaudeOAuthCredentials
    private let renew: @Sendable (ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials
    private let fetch: @Sendable (ClaudeOAuthCredentials) async throws -> CodexUsageSnapshot
    private let clock: @Sendable () -> Date

    public init() {
        self.init(
            keychain: ClaudeOAuthKeychain(),
            authenticate: { try await ClaudeOAuthClient().login(onURL: $0) },
            renew: { try await ClaudeOAuthClient().refresh($0) },
            fetch: { try await ClaudeClient().fetchUsage(accessToken: $0.accessToken, identity: $0.identity) }
        )
    }

    init(
        keychain: ClaudeOAuthKeychain,
        authenticate: @escaping @Sendable (@escaping @Sendable (URL) -> Void) async throws -> ClaudeOAuthCredentials,
        renew: @escaping @Sendable (ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials,
        fetch: @escaping @Sendable (ClaudeOAuthCredentials) async throws -> CodexUsageSnapshot,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.authenticate = authenticate
        self.renew = renew
        self.fetch = fetch
        self.clock = clock
    }

    public func login(profileID: UUID, onURL: @escaping @Sendable (URL) -> Void) async throws -> CodexIdentity {
        try Task.checkCancellation()
        let credentials = try await authenticate(onURL)
        try Task.checkCancellation()
        let previous = try keychain.load(profileID: profileID, allowInteraction: true)
        try Task.checkCancellation()
        try keychain.save(credentials, profileID: profileID, allowInteraction: true)
        // The monitor drains this operation before starting another for this profile.
        // A cancelled save must not replace an existing account's credentials.
        if Task.isCancelled {
            if let previous { try keychain.save(previous, profileID: profileID, allowInteraction: true) }
            else { try keychain.remove(profileID: profileID, allowInteraction: true) }
            throw CancellationError()
        }
        return credentials.identity
    }

    public func fetchUsage(
        profile: AccountProfile, allowKeychainInteraction: Bool = false
    ) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        guard let accountID = profile.oauthIdentity?.accountID,
              var credentials = try keychain.load(profileID: profile.id, allowInteraction: allowKeychainInteraction),
              credentials.accountID == accountID else { throw ClaudeOAuthError.signInRequired }
        let needsRenewal = credentials.expiresAt <= clock().addingTimeInterval(60)
        if needsRenewal {
            credentials = try await renew(credentials)
            try keychain.save(credentials, profileID: profile.id, allowInteraction: allowKeychainInteraction)
        }
        try Task.checkCancellation()
        do {
            return try await fetch(credentials)
        } catch ClaudeClientError.unauthorized where !needsRenewal {
            // A server-rejected token may expire before its advertised timestamp.
            credentials = try await renew(credentials)
            try keychain.save(credentials, profileID: profile.id, allowInteraction: allowKeychainInteraction)
            try Task.checkCancellation()
            return try await fetch(credentials)
        }
    }

    public func disconnect(profileID: UUID) async throws {
        try keychain.remove(profileID: profileID, allowInteraction: true)
    }
}
