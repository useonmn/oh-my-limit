import Foundation

/// Keychain persistence for directly logged-in Codex (ChatGPT) credentials.
public struct CodexOAuthKeychain: Sendable {
    let store: OAuthKeychain<CodexOAuthCredentials>

    public init(service: String = "local.ohmylimit.codex.oauth") {
        store = OAuthKeychain(service: service, security: OAuthSystemSecurity())
    }

    init(service: String, security: any AntigravityOAuthSecurity) {
        store = OAuthKeychain(service: service, security: security)
    }

    public func load(profileID: UUID, allowInteraction: Bool = false) throws -> CodexOAuthCredentials? {
        try store.load(profileID: profileID, allowInteraction: allowInteraction)
    }

    public func save(_ credentials: CodexOAuthCredentials, profileID: UUID, allowInteraction: Bool = false) throws {
        try store.save(credentials, profileID: profileID, allowInteraction: allowInteraction)
    }

    public func remove(profileID: UUID, allowInteraction: Bool = false) throws {
        try store.remove(profileID: profileID, allowInteraction: allowInteraction)
    }
}

/// Owns this app's credentials only; direct accounts never fall back to a CLI home.
public struct CodexDirectClient: Sendable {
    private let flow: OAuthDirectFlow<CodexOAuthCredentials>

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
        flow = OAuthDirectFlow(keychain: keychain.store, authenticate: authenticate, renew: renew,
                               fetch: fetch, isUnauthorized: { ($0 as? CodexOAuthError) == .signInRequired }, clock: clock)
    }

    public func login(profileID: UUID, onURL: @escaping @Sendable (URL) -> Void) async throws -> CodexIdentity {
        try await flow.login(profileID: profileID, onURL: onURL)
    }

    public func fetchUsage(
        profile: AccountProfile, allowKeychainInteraction: Bool = false
    ) async throws -> CodexUsageSnapshot {
        try await flow.fetchUsage(profile: profile, allowKeychainInteraction: allowKeychainInteraction)
    }

    public func disconnect(profileID: UUID) async throws {
        try await flow.disconnect(profileID: profileID)
    }
}
