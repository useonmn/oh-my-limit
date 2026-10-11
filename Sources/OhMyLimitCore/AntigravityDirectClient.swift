import Foundation

/// Owns this app's credentials only; direct accounts never fall back to local login.
public struct AntigravityDirectClient: Sendable {
    private let flow: OAuthDirectFlow<AntigravityOAuthCredentials>

    public init() {
        self.init(
            keychain: AntigravityOAuthKeychain(),
            authenticate: { try await AntigravityOAuthClient().login(onURL: $0) },
            renew: { try await AntigravityOAuthClient().refresh($0) },
            fetch: { try await AntigravityRemoteClient().fetchUsage(credentials: $0) }
        )
    }

    init(
        keychain: AntigravityOAuthKeychain,
        authenticate: @escaping @Sendable (@escaping @Sendable (URL) -> Void) async throws -> AntigravityOAuthCredentials,
        renew: @escaping @Sendable (AntigravityOAuthCredentials) async throws -> AntigravityOAuthCredentials,
        fetch: @escaping @Sendable (AntigravityOAuthCredentials) async throws -> CodexUsageSnapshot,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        flow = OAuthDirectFlow(keychain: keychain.store, authenticate: authenticate, renew: renew,
                               fetch: fetch, isUnauthorized: { ($0 as? AntigravityOAuthError) == .signInRequired }, clock: clock)
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
