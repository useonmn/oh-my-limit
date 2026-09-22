import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct CodexDirectAccountTests {
    @Test @MainActor func loginPersistsIdentityEvenWhenUsageIsDenied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CodexOAuthKeychain(service: "fixture.codex.monitor", security: OAuthFakeSecurity())
        let credentials = codexCredentials()
        let direct = CodexDirectClient(
            keychain: keychain,
            authenticate: { _ in credentials },
            renew: { $0 },
            fetch: { _ in throw CodexOAuthError.signInRequired }
        )
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: nil,
            fetch: { _, _ in
                Issue.record("Direct login must not use the CLI")
                throw CodexClientError.timedOut
            },
            directCodex: direct
        )
        let id = try #require(monitor.createCodexAccount())

        await monitor.login(id, onURL: { _ in })?.value

        #expect(monitor.accounts[0].profile.oauthIdentity == credentials.identity)
        #expect(monitor.accounts[0].profile.authentication == .oauth)
        #expect(monitor.accounts[0].snapshot == nil)
        #expect(monitor.accounts[0].error == CodexOAuthError.signInRequired.localizedDescription)
        #expect(!monitor.isWorking)
        #expect(try monitor.store.load()[0].oauthIdentity == credentials.identity)
        #expect(try keychain.load(profileID: id) == credentials)
        await monitor.disconnect(id)?.value
        #expect(monitor.accounts.isEmpty)
        #expect(try keychain.load(profileID: id) == nil)
    }

    @Test @MainActor func directCodexAccountsStaySeparateFromLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CodexOAuthKeychain(service: "fixture.codex.monitor", security: OAuthFakeSecurity())
        let credentials = codexCredentials()
        let direct = CodexDirectClient(
            keychain: keychain,
            authenticate: { _ in credentials },
            renew: { $0 },
            fetch: { input in
                CodexUsageSnapshot(identity: input.identity, windows: [], source: .codexOAuth)
            }
        )
        let monitor = UsageMonitor(store: AccountStore(directory: root), executableURL: nil, directCodex: direct)
        let first = try #require(monitor.createCodexAccount(name: "First"))
        let second = try #require(monitor.createCodexAccount(name: "Second"))
        #expect(first != second)
        await monitor.login(first, onURL: { _ in })?.value
        #expect(monitor.accounts[0].snapshot?.source == .codexOAuth)
        #expect(monitor.accounts[0].profile.oauthIdentity?.email == credentials.email)
        let restored = UsageMonitor(store: monitor.store, executableURL: nil)
        #expect(restored.accounts[0].snapshot == monitor.accounts[0].snapshot)
        #expect(restored.accounts[0].profile.authentication == .oauth)
    }
}
