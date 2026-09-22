import Foundation

/// Owns this app's credentials only; direct accounts never fall back to local login.
public struct AntigravityDirectClient: Sendable {
    private let keychain: AntigravityOAuthKeychain
    private let authenticate: @Sendable (@escaping @Sendable (URL) -> Void) async throws -> AntigravityOAuthCredentials
    private let renew: @Sendable (AntigravityOAuthCredentials) async throws -> AntigravityOAuthCredentials
    private let fetch: @Sendable (AntigravityOAuthCredentials) async throws -> CodexUsageSnapshot
    private let clock: @Sendable () -> Date

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
              credentials.accountID == accountID else { throw AntigravityOAuthError.signInRequired }
        let needsRenewal = credentials.expiresAt <= clock().addingTimeInterval(60)
        if needsRenewal {
            credentials = try await renew(credentials)
            try await keychain.save(credentials, profileID: profile.id, allowInteraction: allowKeychainInteraction)
        }
        try Task.checkCancellation()
        do {
            return try await fetch(credentials)
        } catch AntigravityOAuthError.signInRequired where !needsRenewal {
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
