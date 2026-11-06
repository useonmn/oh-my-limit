import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityDirectAccountTests {
    @Test @MainActor func loginPersistsIdentityEvenWhenQuotaIsDenied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = AntigravityOAuthKeychain(service: "fixture.monitor", security: OAuthFakeSecurity())
        let credentials = oauthCredentials()
        let direct = AntigravityDirectClient(
            keychain: keychain, authenticate: { _ in credentials }, renew: { $0 },
            fetch: { _ in throw AntigravityOAuthError.quotaUnavailable }
        )
        let monitor = UsageMonitor(
            store: AccountStore(directory: root),
            fetchAntigravity: {
                Issue.record("Direct login must not use a local account")
                throw AntigravityOAuthError.quotaUnavailable
            }, directAntigravity: direct
        )
        let id = try #require(monitor.createAntigravityAccount())

        await monitor.login(id, onURL: { _ in })?.value

        #expect(monitor.accounts[0].profile.oauthIdentity == credentials.identity)
        #expect(monitor.accounts[0].snapshot == nil)
        #expect(monitor.accounts[0].error == AntigravityOAuthError.quotaUnavailable.localizedDescription)
        #expect(!monitor.isWorking)
        #expect(try monitor.store.load()[0].oauthIdentity == credentials.identity)
        #expect(try await keychain.load(profileID: id) == credentials)
        await monitor.disconnect(id)?.value
        #expect(monitor.accounts.isEmpty)
        #expect(try await keychain.load(profileID: id) == nil)
    }

    @Test @MainActor func directAccountsStaySeparateFromLocalAndCacheIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = AntigravityOAuthKeychain(service: "fixture.monitor", security: OAuthFakeSecurity())
        let credentials = oauthCredentials()
        let direct = AntigravityDirectClient(
            keychain: keychain, authenticate: { _ in credentials }, renew: { $0 },
            fetch: { input in
                CodexUsageSnapshot(identity: input.identity, windows: [], source: .antigravityOAuth)
            }
        )
        let monitor = UsageMonitor(store: AccountStore(directory: root), directAntigravity: direct)
        let first = try #require(monitor.createAntigravityAccount(name: "First"))
        let second = try #require(monitor.createAntigravityAccount(name: "Second"))
        let local = try #require(monitor.connectAntigravity())
        #expect(first != second && local != first && local != second)
        #expect(monitor.connectAntigravity() == local)
        await monitor.login(first, onURL: { _ in })?.value
        #expect(monitor.accounts[0].snapshot?.source == .antigravityOAuth)
        let restored = UsageMonitor(store: monitor.store)
        #expect(restored.accounts[0].snapshot == monitor.accounts[0].snapshot)
        var profiles = try monitor.store.load()
        profiles[0].oauthIdentity = CodexIdentity(email: "other@example.invalid", accountID: "other")
        try monitor.store.save(profiles)
        let changed = UsageMonitor(store: monitor.store)
        #expect(changed.accounts[0].snapshot == nil)
        #expect(try await keychain.load(profileID: second) == nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func disconnectDrainsCancelledLoginBeforeRemovingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DirectLoginGate()
        var started = gate.started.makeAsyncIterator()
        let keychain = AntigravityOAuthKeychain(service: "fixture.monitor", security: OAuthFakeSecurity())
        let direct = AntigravityDirectClient(
            keychain: keychain, authenticate: { _ in await gate.wait() }, renew: { $0 },
            fetch: { _ in throw AntigravityOAuthError.quotaUnavailable }
        )
        let monitor = UsageMonitor(store: AccountStore(directory: root), directAntigravity: direct)
        let id = try #require(monitor.createAntigravityAccount())
        let pendingLogin = monitor.login(id, onURL: { _ in })
        let login = try #require(pendingLogin)
        _ = await started.next()
        let disconnect = try #require(monitor.disconnect(id))
        await gate.release(oauthCredentials())
        await login.value
        await disconnect.value
        #expect(monitor.accounts.isEmpty)
        #expect(try monitor.store.load().isEmpty)
        #expect(try await keychain.load(profileID: id) == nil)
    }

    @Test func oauthConnectionAndIdentitySurvivePersistence() throws {
        let input = Data(#"""
        {"id":"5E601632-EAF7-4F82-87B5-28BACFC9821B","name":"Google","homePath":"/local/oauth/profile","isManaged":false,"provider":"antigravity","authentication":"oauth","oauthIdentity":{"email":"direct@example.invalid","accountID":"google-123"}}
        """#.utf8)
        let profile = try JSONDecoder().decode(AccountProfile.self, from: input)

        let output = try JSONEncoder().encode(profile)

        let fields = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(fields["authentication"] as? String == "oauth")
        let identity = fields["oauthIdentity"] as? [String: Any]
        #expect(identity?["accountID"] as? String == "google-123")
    }
}

private actor DirectLoginGate {
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<AntigravityOAuthCredentials, Never>?

    init() { (started, signal) = AsyncStream.makeStream() }
    func wait() async -> AntigravityOAuthCredentials {
        await withCheckedContinuation {
            continuation = $0
            signal.yield(())
        }
    }
    func release(_ credentials: AntigravityOAuthCredentials) {
        continuation?.resume(returning: credentials)
        continuation = nil
        signal.finish()
    }
}
