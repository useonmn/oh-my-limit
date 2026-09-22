import Foundation
import LocalAuthentication
import Security

/// Keychain persistence for directly logged-in Codex (ChatGPT) credentials.
public struct CodexOAuthKeychain: Sendable {
    private let service: String
    private let security: any AntigravityOAuthSecurity

    public init(service: String = "local.ohmylimit.codex.oauth") {
        self.init(service: service, security: OAuthSystemSecurity())
    }

    init(service: String, security: any AntigravityOAuthSecurity) {
        self.service = service
        self.security = security
    }

    public func load(profileID: UUID, allowInteraction: Bool = false) throws -> CodexOAuthCredentials? {
        var query = self.query(profileID: profileID, allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data,
                  let credentials = try? JSONDecoder().decode(CodexOAuthCredentials.self, from: data),
                  CodexOAuthClient.valid(credentials) else { return nil }
            return credentials
        case errSecItemNotFound: return nil
        default: throw CodexOAuthError.storageFailure(status)
        }
    }

    public func save(_ credentials: CodexOAuthCredentials, profileID: UUID, allowInteraction: Bool = false) throws {
        guard CodexOAuthClient.valid(credentials),
              let data = try? JSONEncoder().encode(credentials) else {
            throw CodexOAuthError.invalidResponse
        }
        let query = self.query(profileID: profileID, allowInteraction: allowInteraction)
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
        guard status == errSecSuccess else { throw CodexOAuthError.storageFailure(status) }
    }

    public func remove(profileID: UUID, allowInteraction: Bool = false) throws {
        let status = security.delete(self.query(profileID: profileID, allowInteraction: allowInteraction))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexOAuthError.storageFailure(status)
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

/// Owns this app's credentials only; direct accounts never fall back to a CLI home.
public struct CodexDirectClient: Sendable {
    private let keychain: CodexOAuthKeychain
    private let authenticate: @Sendable (@escaping @Sendable (URL) -> Void) async throws -> CodexOAuthCredentials
    private let renew: @Sendable (CodexOAuthCredentials) async throws -> CodexOAuthCredentials
    private let fetch: @Sendable (CodexOAuthCredentials) async throws -> CodexUsageSnapshot
    private let clock: @Sendable () -> Date

    public init() {
        self.init(
            keychain: CodexOAuthKeychain(),
            authenticate: { try await CodexOAuthClient().login(onURL: $0) },
            renew: { try await CodexOAuthClient().refresh($0) },
            fetch: { try await CodexRemoteClient().fetchUsage($0) }
        )
    }

    init(
        keychain: CodexOAuthKeychain,
        authenticate: @escaping @Sendable (@escaping @Sendable (URL) -> Void) async throws -> CodexOAuthCredentials,
        renew: @escaping @Sendable (CodexOAuthCredentials) async throws -> CodexOAuthCredentials,
        fetch: @escaping @Sendable (CodexOAuthCredentials) async throws -> CodexUsageSnapshot,
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
        let previous = try await keychain.load(profileID: profileID, allowInteraction: true)
        try Task.checkCancellation()
        try await keychain.save(credentials, profileID: profileID, allowInteraction: true)
        // The monitor drains this operation before starting another for this profile.
        // A cancelled save must not replace an existing account's credentials.
        if Task.isCancelled {
            if let previous { try await keychain.save(previous, profileID: profileID, allowInteraction: true) }
            else { try await keychain.remove(profileID: profileID, allowInteraction: true) }
            throw CancellationError()
        }
        return credentials.identity
    }

    public func fetchUsage(
        profile: AccountProfile, allowKeychainInteraction: Bool = false
    ) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        guard let identity = profile.oauthIdentity, let accountID = identity.accountID,
              var credentials = try await keychain.load(
                profileID: profile.id, allowInteraction: allowKeychainInteraction
              ),
              credentials.accountID == accountID else { throw CodexOAuthError.signInRequired }
        let needsRenewal = credentials.expiresAt <= clock().addingTimeInterval(60)
        if needsRenewal {
            credentials = try await renew(credentials)
            try await keychain.save(credentials, profileID: profile.id, allowInteraction: allowKeychainInteraction)
        }
        try Task.checkCancellation()
        do {
            return try await fetch(credentials)
        } catch CodexOAuthError.signInRequired where !needsRenewal {
            // A server-rejected token may expire before its advertised timestamp.
            credentials = try await renew(credentials)
            try await keychain.save(credentials, profileID: profile.id, allowInteraction: allowKeychainInteraction)
            try Task.checkCancellation()
            return try await fetch(credentials)
        }
    }

    public func disconnect(profileID: UUID) async throws {
        try await keychain.remove(profileID: profileID, allowInteraction: true)
    }
}
