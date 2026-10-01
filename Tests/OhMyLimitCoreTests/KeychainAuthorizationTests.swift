import Foundation
import Security
import Testing
@testable import OhMyLimitCore

@Suite @MainActor struct KeychainAuthorizationTests {
    @Test(arguments: [AccountProvider.codex, .antigravity])
    func deniedGrantPreservesAccountAndSuccessfulGrantIsPerAccount(_ provider: AccountProvider) async throws {
        let setup = try await AuthorizationSetup(provider: provider)
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let monitor = setup.monitor
        let first = setup.profiles[0].id
        let second = setup.profiles[1].id
        for task in monitor.refreshAll() { await task.value }
        let snapshots = monitor.accounts.map(\.snapshot)
        let cacheURL = setup.root.appendingPathComponent("snapshots/\(first.uuidString).json")
        let cache = try Data(contentsOf: cacheURL)
        setup.security.requiresAuthorization = true

        for task in monitor.refreshAll(manual: false) { await task.value }

        #expect(monitor.accounts.allSatisfy { $0.needsKeychainAccess })
        #expect(setup.security.interactionAccounts.isEmpty)
        let denied = try #require(monitor.authorizeKeychain(first))
        await denied.value
        #expect(monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[0].error != nil)
        #expect(monitor.accounts.map(\.profile) == setup.profiles)
        #expect(try monitor.store.load() == setup.profiles)
        #expect(monitor.accounts.map(\.snapshot) == snapshots)
        #expect(try Data(contentsOf: cacheURL) == cache)
        #expect(setup.security.deleteCount == 0)
        #expect(setup.security.interactionAccounts == [first.uuidString])
        setup.security.requiresAuthorization = false
        try await setup.expectOriginalCredentials()
        setup.security.requiresAuthorization = true
        setup.security.grantsAuthorization = true

        let granted = try #require(monitor.authorizeKeychain(first))
        await granted.value

        #expect(!monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[0].error == nil)
        #expect(monitor.accounts[0].profile == setup.profiles[0])
        #expect(monitor.accounts[1].needsKeychainAccess)
        #expect(setup.security.interactionAccounts == [first.uuidString, first.uuidString])
        let ordinary = try #require(monitor.refresh(first, manual: false))
        await ordinary.value
        await monitor.refresh(second)?.value
        #expect(Array(setup.security.interactionPolicies.suffix(2)) == [false, false])
        #expect(!monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[1].needsKeychainAccess)
        #expect(setup.security.interactionAttempts == 2)
        #expect(!monitor.isWorking)
        setup.security.requiresAuthorization = false
        try await setup.expectOriginalCredentials()
    }

    @Test(arguments: [AccountProvider.codex, .antigravity],
          [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed])
    func typedStorageFailuresRequireAuthorization(_ provider: AccountProvider, _ status: OSStatus) async throws {
        let setup = try await AuthorizationSetup(provider: provider)
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let monitor = setup.monitor
        let id = setup.profiles[0].id
        setup.security.status = status
        await monitor.refresh(id)?.value
        #expect(monitor.accounts[0].needsKeychainAccess)
        setup.security.status = errSecUserCanceled
        await monitor.authorizeKeychain(id)?.value
        #expect(monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[0].profile == setup.profiles[0])
        setup.security.status = errSecSuccess
        setup.security.corrupt = true
        await monitor.authorizeKeychain(id)?.value
        #expect(!monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[0].error != nil)
        setup.security.corrupt = false
        await monitor.refresh(id)?.value
        #expect(!monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[0].error == nil)
    }

    @Test(arguments: [AccountProvider.codex, .antigravity])
    func authorizationRejectsLocalMissingAndShutdownAccounts(_ provider: AccountProvider) async throws {
        let setup = try await AuthorizationSetup(provider: provider)
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let local = try #require(setup.monitor.connectAntigravity())
        #expect(setup.monitor.authorizeKeychain(local) == nil)
        #expect(setup.monitor.authorizeKeychain(UUID()) == nil)
        await setup.monitor.stopAndWait()
        #expect(setup.monitor.authorizeKeychain(setup.profiles[0].id) == nil)
        #expect(setup.security.interactionAccounts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [AccountProvider.codex, .antigravity])
    func authorizationDeduplicatesAndDrainsBeforeDisconnect(_ provider: AccountProvider) async throws {
        let gate = AuthorizationFetchGate()
        var started = gate.started.makeAsyncIterator()
        let setup = try await AuthorizationSetup(provider: provider, fetch: { try await gate.wait($0) })
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let monitor = setup.monitor
        let id = setup.profiles[0].id
        let authorization = try #require(monitor.authorizeKeychain(id))
        _ = await started.next()
        #expect(monitor.accounts[0].isRefreshing)
        #expect(!monitor.accounts[0].isLoggingIn)
        #expect(monitor.authorizeKeychain(id) == nil)
        #expect(monitor.refresh(id) == nil)
        monitor.cancel(id)
        let disconnect = try #require(monitor.disconnect(id))
        #expect(monitor.authorizeKeychain(id) == nil)
        #expect(setup.security.deleteCount == 0)
        await gate.release()
        await authorization.value
        await disconnect.value
        #expect(monitor.accounts.map(\.id) == [setup.profiles[1].id])
        #expect(setup.security.deleteCount == 1)
        #expect(!FileManager.default.fileExists(
            atPath: setup.root.appendingPathComponent("snapshots/\(id.uuidString).json").path
        ))
        #expect(!monitor.isWorking)
    }
}

private actor AuthorizationFetchGate {
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?

    init() { (started, signal) = AsyncStream.makeStream() }
    func wait(_ identity: CodexIdentity) async throws -> CodexUsageSnapshot {
        await withCheckedContinuation {
            continuation = $0
            signal.yield(())
        }
        return CodexUsageSnapshot(identity: identity, windows: [])
    }
    func release() {
        continuation?.resume()
        continuation = nil
        signal.finish()
    }
}

@MainActor private struct AuthorizationSetup {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let security = OAuthFakeSecurity()
    let google = AntigravityOAuthCredentials(
        accessToken: "google-access", refreshToken: "google-refresh",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        accountID: "google-id", email: "google@example.invalid"
    )
    let codex = CodexOAuthCredentials(
        accessToken: "codex-access", refreshToken: "codex-refresh",
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        accountID: "codex-id", email: "codex@example.invalid"
    )
    let profiles: [AccountProfile]
    let monitor: UsageMonitor
    let googleKeychain: AntigravityOAuthKeychain
    let codexKeychain: CodexOAuthKeychain

    init(
        provider: AccountProvider,
        fetch: (@Sendable (CodexIdentity) async throws -> CodexUsageSnapshot)? = nil
    ) async throws {
        googleKeychain = AntigravityOAuthKeychain(service: "test.authorization.google", security: security)
        codexKeychain = CodexOAuthKeychain(service: "test.authorization.codex", security: security)
        let identity = provider == .codex ? codex.identity : google.identity
        let homePath = root.path
        profiles = ["First", "Second"].map {
            AccountProfile(name: $0, homePath: homePath, isManaged: false,
                           provider: provider, authentication: .oauth, oauthIdentity: identity)
        }
        for profile in profiles {
            if provider == .codex { try codexKeychain.save(codex, profileID: profile.id) }
            else { try await googleKeychain.save(google, profileID: profile.id) }
        }
        let store = AccountStore(directory: root)
        try store.save(profiles)
        monitor = UsageMonitor(
            store: store,
            directAntigravity: AntigravityDirectClient(
                keychain: googleKeychain,
                authenticate: { _ in
                    Issue.record("Keychain authorization must not start Google OAuth")
                    throw AntigravityOAuthError.signInRequired
                },
                renew: { $0 },
                fetch: {
                    if let fetch { return try await fetch($0.identity) }
                    return CodexUsageSnapshot(identity: $0.identity, windows: [],
                                              fetchedAt: .distantPast, source: .antigravityOAuth)
                },
                clock: { Date(timeIntervalSince1970: 1_900_000_000) }
            ),
            directCodex: CodexDirectClient(
                keychain: codexKeychain,
                authenticate: { _ in
                    Issue.record("Keychain authorization must not start ChatGPT OAuth")
                    throw CodexOAuthError.signInRequired
                },
                renew: { $0 },
                fetch: {
                    if let fetch { return try await fetch($0.identity) }
                    return CodexUsageSnapshot(identity: $0.identity, windows: [],
                                              fetchedAt: .distantPast, source: .codexOAuth)
                },
                clock: { Date(timeIntervalSince1970: 1_900_000_000) }
            )
        )
    }

    func expectOriginalCredentials() async throws {
        for profile in profiles {
            if profile.provider == .codex {
                #expect(try codexKeychain.load(profileID: profile.id) == codex)
            } else {
                #expect(try await googleKeychain.load(profileID: profile.id) == google)
            }
        }
    }
}
