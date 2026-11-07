import Combine
import Foundation
import Security
import Testing
@testable import OhMyLimitCore

@MainActor
struct UsageMonitorTests {
    private let now = Date(timeIntervalSince1970: 1_789_400_000)

    nonisolated private func snapshot(percent: Double = 34, identity: CodexIdentity = CodexIdentity(
        email: "test@example.com", planType: "plus"
    )) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            identity: identity,
            windows: [CodexQuotaWindow(
                id: "codex.primary", label: "주간", usedPercent: percent,
                windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(3600)
            )], fetchedAt: now, source: .codexOAuth
        )
    }

    nonisolated private func credentials(_ index: Int) -> CodexOAuthCredentials {
        CodexOAuthCredentials(accessToken: "fixture-access-\(index)", refreshToken: "fixture-refresh-\(index)",
                              expiresAt: now.addingTimeInterval(86_400),
                              accountID: "acct-\(index)", email: "account-\(index)@example.invalid")
    }

    private func codexAccounts(
        _ names: [String], root: URL,
        authenticate: @escaping @Sendable (@escaping @Sendable (URL) -> Void) async throws -> CodexOAuthCredentials = { _ in
            Issue.record("Unexpected ChatGPT login")
            throw CodexOAuthError.signInRequired
        },
        fetch: @escaping @Sendable (CodexOAuthCredentials) async throws -> CodexUsageSnapshot,
        fetchAntigravity: @escaping UsageMonitor.AntigravityFetch = {
            Issue.record("Unexpected Antigravity fetch")
            throw AntigravityClientError.localUnavailable
        },
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_789_400_000) }
    ) throws -> (UsageMonitor, [AccountProfile]) {
        let keychain = CodexOAuthKeychain(service: "fixture.codex.monitor", security: OAuthFakeSecurity())
        let profiles = names.enumerated().map { index, name in
            AccountProfile(name: name, homePath: root.path, isManaged: false, authentication: .oauth,
                           oauthIdentity: credentials(index + 1).identity)
        }
        for (index, profile) in profiles.enumerated() {
            try keychain.save(credentials(index + 1), profileID: profile.id)
        }
        let store = AccountStore(directory: root)
        try store.save(profiles)
        let monitor = makeMonitor(
            store: store, fetchAntigravity: fetchAntigravity,
            directCodex: CodexDirectClient(keychain: keychain, authenticate: authenticate,
                                           renew: { _ in
                                               Issue.record("Unexpected Codex renewal")
                                               throw CodexOAuthError.signInRequired
                                           }, fetch: fetch, clock: clock),
            clock: clock
        )
        return (monitor, profiles)
    }

    private func makeMonitor(
        store: AccountStore,
        fetchAntigravity: @escaping UsageMonitor.AntigravityFetch = {
            Issue.record("Unexpected local Antigravity fetch")
            throw AntigravityClientError.localUnavailable
        },
        directCodex: CodexDirectClient? = nil,
        directClaude: ClaudeDirectClient? = nil,
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_789_400_000) }
    ) -> UsageMonitor {
        UsageMonitor(
            store: store, fetchAntigravity: fetchAntigravity,
            directAntigravity: AntigravityDirectClient(
                keychain: AntigravityOAuthKeychain(service: "fixture.unexpected", security: UnexpectedMonitorSecurity()),
                authenticate: { _ in
                    Issue.record("Unexpected Antigravity login")
                    throw AntigravityOAuthError.signInRequired
                }, renew: { _ in
                    Issue.record("Unexpected Antigravity renewal")
                    throw AntigravityOAuthError.signInRequired
                }, fetch: { _ in
                    Issue.record("Unexpected Antigravity fetch")
                    throw AntigravityOAuthError.signInRequired
                }, clock: clock
            ),
            directCodex: directCodex ?? CodexDirectClient(
                keychain: CodexOAuthKeychain(service: "fixture.unexpected", security: UnexpectedMonitorSecurity()),
                authenticate: { _ in
                    Issue.record("Unexpected Codex login")
                    throw CodexOAuthError.signInRequired
                }, renew: { _ in
                    Issue.record("Unexpected Codex renewal")
                    throw CodexOAuthError.signInRequired
                }, fetch: { _ in
                    Issue.record("Unexpected Codex fetch")
                    throw CodexOAuthError.signInRequired
                }, clock: clock
            ),
            directClaude: directClaude ?? ClaudeDirectClient(
                keychain: ClaudeOAuthKeychain(service: "fixture.unexpected", security: UnexpectedMonitorSecurity()),
                authenticate: { _ in
                    Issue.record("Unexpected Claude login")
                    throw ClaudeOAuthError.signInRequired
                }, renew: { _ in
                    Issue.record("Unexpected Claude renewal")
                    throw ClaudeOAuthError.signInRequired
                }, fetch: { _ in
                    Issue.record("Unexpected Claude fetch")
                    throw ClaudeOAuthError.signInRequired
                }, clock: clock
            ), clock: clock
        )
    }

    @Test(arguments: [(100.0, 3.0), (42.0, 99.0)])
    func codexSummaryUsesMainWeeklyQuotaInsteadOfReserve(_ percentages: (Double, Double)) throws {
        let state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false, authentication: .oauth),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: [
                CodexQuotaWindow(id: "base_model_inference.primary", label: "gpt-reserve",
                    usedPercent: percentages.1, windowDurationMins: 10_080, resetsAt: nil),
                CodexQuotaWindow(id: "codex.primary", label: "주간",
                    usedPercent: percentages.0, windowDurationMins: 10_080, resetsAt: nil),
                CodexQuotaWindow(id: "codex_bengalfox.secondary", label: "Spark",
                    usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil)
            ], fetchedAt: now)
        )

        #expect(state.menuWindow?.id == "codex.primary")
        #expect(state.menuWindow?.usedPercent == percentages.0)
    }

    @Test func codexSummaryPrefersMainShortWindowOverReserveWeekly() throws {
        let state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false, authentication: .oauth),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: [
                CodexQuotaWindow(id: "base_model_inference.primary", label: "gpt-reserve",
                    usedPercent: 3, windowDurationMins: 10_080, resetsAt: nil),
                CodexQuotaWindow(id: "codex.primary", label: "5시간",
                    usedPercent: 55, windowDurationMins: 300, resetsAt: nil)
            ], fetchedAt: now)
        )

        #expect(state.menuWindow?.id == "codex.primary")
        #expect(state.menuWindow?.usedPercent == 55)
    }

    @Test func codexSummaryDoesNotSubstituteReserveWhenMainQuotaIsUnavailable() {
        let state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false, authentication: .oauth),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: [
                CodexQuotaWindow(id: "base_model_inference.primary", label: "gpt-reserve",
                    usedPercent: 3, windowDurationMins: 10_080, resetsAt: nil),
                CodexQuotaWindow(id: "codex.primary", label: "주간",
                    usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil, usageKnown: false),
                CodexQuotaWindow(id: "codex_bengalfox.secondary", label: "Spark",
                    usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil)
            ], fetchedAt: now)
        )

        #expect(state.menuWindow == nil)
    }

    @Test func retiredCLIConnectionsAreDroppedOnLoadWithoutTouchingTheirFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Retired-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("home with spaces ; literal/.codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let auth = codexHome.appendingPathComponent("auth.json")
        let credential = Data("test-credential-sentinel".utf8)
        try credential.write(to: auth)
        let managed = UUID(), existing = UUID(), claudeCode = UUID()
        let antigravity = UUID(), codexOAuth = UUID(), claudeOAuth = UUID()
        let document = """
        {"version":3,"accounts":[
          {"id":"\(managed)","name":"Managed","homePath":"\(root.path)/profiles/\(managed)","isManaged":true},
          {"id":"\(existing)","name":"Existing","homePath":"\(codexHome.path)","isManaged":false,"provider":"codex","authentication":"local"},
          {"id":"\(claudeCode)","name":"Claude Code","homePath":"/Users/fixture/.claude","isManaged":false,"provider":"claude","authentication":"local"},
          {"id":"\(antigravity)","name":"Antigravity","homePath":"/Users/fixture","isManaged":false,"provider":"antigravity","authentication":"local"},
          {"id":"\(codexOAuth)","name":"ChatGPT","homePath":"\(root.path)","isManaged":false,"provider":"codex","authentication":"oauth"},
          {"id":"\(claudeOAuth)","name":"Claude","homePath":"\(root.path)","isManaged":false,"provider":"claude","authentication":"oauth"}
        ]}
        """
        try FileManager.default.createDirectory(at: root.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try Data(document.utf8).write(to: root.appendingPathComponent("accounts.json"))
        let retiredCache = root.appendingPathComponent("snapshots/\(existing.uuidString).json")
        try Data("{}".utf8).write(to: retiredCache)
        let store = AccountStore(directory: root)

        let monitor = makeMonitor(store: store)

        #expect(monitor.accounts.map(\.id) == [antigravity, codexOAuth, claudeOAuth])
        #expect(monitor.notice != nil)
        #expect(try store.load().map(\.id) == [antigravity, codexOAuth, claudeOAuth])
        #expect(!FileManager.default.fileExists(atPath: retiredCache.path))
        #expect(try Data(contentsOf: auth) == credential)
        #expect(monitor.createCodexAccount() != nil)
        let reloaded = makeMonitor(store: store)
        #expect(reloaded.accounts.count == 4)
        #expect(reloaded.notice == nil)
    }

    @Test func antigravityLoginNeverStartsCodexAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (monitor, _) = try codexAccounts([], root: root, fetch: { _ in
            Issue.record("Antigravity must not invoke the Codex fetch adapter")
            throw CodexOAuthError.signInRequired
        })
        let id = try #require(monitor.connectAntigravity())

        let request = monitor.login(id, onURL: { _ in })
        await request?.value

        #expect(request == nil)
        #expect(monitor.accounts[0].snapshot == nil)
    }

    @Test func antigravityMenuExcludesUnknownUsageAndSelectsTheMostConsumedWeeklyPool() {
        let profile = AccountProfile(
            name: "Antigravity", homePath: "/local/user", isManaged: false, provider: .antigravity
        )
        let windows = [
            CodexQuotaWindow(id: "unknown", label: "Unknown", usedPercent: 0,
                windowDurationMins: 10_080, resetsAt: nil, usageKnown: false),
            CodexQuotaWindow(id: "gemini-weekly", label: "Gemini", usedPercent: 25,
                windowDurationMins: 10_080, resetsAt: nil),
            CodexQuotaWindow(id: "claude-weekly", label: "Claude + GPT", usedPercent: 82,
                windowDurationMins: 10_080, resetsAt: nil),
            CodexQuotaWindow(id: "gemini-session", label: "Gemini", usedPercent: 99,
                windowDurationMins: 300, resetsAt: nil),
        ]
        let state = AccountState(
            profile: profile,
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: windows, fetchedAt: now)
        )

        #expect(state.menuWindow?.id == "claude-weekly")
    }

    nonisolated private func antigravityWindows() -> [CodexQuotaWindow] {
        [
            CodexQuotaWindow(id: "gemini-5h", label: "Gemini", usedPercent: 90,
                windowDurationMins: 300, resetsAt: nil),
            CodexQuotaWindow(id: "gemini-weekly", label: "Gemini", usedPercent: 20,
                windowDurationMins: 10_080, resetsAt: nil),
            CodexQuotaWindow(id: "3p-weekly", label: "Claude + GPT", usedPercent: 70,
                windowDurationMins: 10_080, resetsAt: nil),
        ]
    }

    @Test func visibleWindowsKeepServerOrderAndFallBackWhenNoSelectedModelExists() {
        var state = AccountState(
            profile: AccountProfile(name: "Antigravity", homePath: "/local/user", isManaged: false,
                                    provider: .antigravity),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: antigravityWindows(), fetchedAt: now)
        )
        #expect(state.visibleWindows.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-weekly"])
        #expect(state.hiddenWindowCount == 0)

        state.profile.visibleWindowIDs = ["3p-weekly", "gemini-5h", "renamed-model"]
        #expect(state.visibleWindows.map(\.id) == ["gemini-5h", "3p-weekly"])
        #expect(state.hiddenWindowCount == 1)

        state.profile.visibleWindowIDs = ["renamed-model"]
        #expect(state.visibleWindows.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-weekly"])
        #expect(state.hiddenWindowCount == 0)
    }

    @Test func antigravityMenuChoosesOnlyAmongSelectedWindows() {
        var state = AccountState(
            profile: AccountProfile(name: "Antigravity", homePath: "/local/user", isManaged: false,
                                    provider: .antigravity),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: antigravityWindows(), fetchedAt: now)
        )
        #expect(state.menuWindow?.id == "3p-weekly")

        state.profile.visibleWindowIDs = ["gemini-5h", "gemini-weekly"]
        #expect(state.menuWindow?.id == "gemini-weekly")

        state.profile.visibleWindowIDs = ["gemini-5h"]
        #expect(state.menuWindow?.id == "gemini-5h")
    }

    @Test func codexMenuShowsASelectedWindowWhenMainQuotaIsHidden() {
        var state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false, authentication: .oauth),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: [
                CodexQuotaWindow(id: "codex.primary", label: "주간", usedPercent: 40,
                    windowDurationMins: 10_080, resetsAt: nil),
                CodexQuotaWindow(id: "spark.primary", label: "Spark", usedPercent: 12,
                    windowDurationMins: 300, resetsAt: nil),
            ], fetchedAt: now)
        )
        #expect(state.menuWindow?.id == "codex.primary")

        state.profile.visibleWindowIDs = ["spark.primary"]
        #expect(state.menuWindow?.id == "spark.primary")
    }

    @Test func visibleWindowSelectionPersistsAndFullSetMeansShowAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Visible-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = CodexUsageSnapshot(
            identity: CodexIdentity(email: "local@example.com"), windows: antigravityWindows(),
            fetchedAt: now, source: .antigravityApp
        )
        let monitor = makeMonitor(store: AccountStore(directory: root), fetchAntigravity: { data })
        let id = try #require(monitor.connectAntigravity())
        await monitor.refresh(id)?.value

        #expect(monitor.setVisibleWindows(id, ["gemini-weekly", "gemini-5h"]))
        #expect(monitor.accounts[0].profile.visibleWindowIDs == ["gemini-5h", "gemini-weekly"])
        #expect(try monitor.store.load()[0].visibleWindowIDs == ["gemini-5h", "gemini-weekly"])

        let restored = makeMonitor(store: monitor.store)
        #expect(restored.accounts[0].profile.visibleWindowIDs == ["gemini-5h", "gemini-weekly"])
        #expect(restored.accounts[0].visibleWindows.map(\.id) == ["gemini-5h", "gemini-weekly"])
        #expect(restored.accounts[0].menuWindow?.id == "gemini-weekly")

        #expect(monitor.setVisibleWindows(id, Set(data.windows.map(\.id))))
        #expect(monitor.accounts[0].profile.visibleWindowIDs == nil)
        #expect(monitor.setVisibleWindows(id, ["3p-weekly"]))
        #expect(monitor.setVisibleWindows(id, nil))
        #expect(try monitor.store.load()[0].visibleWindowIDs == nil)
    }

    @Test func antigravityRefreshNeedsNoCodexAndRestoresItsOwnCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = CodexUsageSnapshot(
            identity: CodexIdentity(email: "local@example.com"), windows: snapshot().windows,
            fetchedAt: now, source: .antigravityApp
        )
        let monitor = makeMonitor(store: AccountStore(directory: root), fetchAntigravity: { data })
        let id = try #require(monitor.connectAntigravity())
        #expect(monitor.connectAntigravity() == id)

        let request = try #require(monitor.refresh(id))
        await request.value

        #expect(monitor.accounts.count == 1)
        #expect(monitor.accounts[0].snapshot == data)
        #expect(monitor.accounts[0].error == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles").path))
        let restored = makeMonitor(store: monitor.store)
        #expect(restored.accounts[0].profile.provider == .antigravity)
        #expect(restored.accounts[0].snapshot == data)
    }

    @Test func localAntigravityDisconnectDeletesPrivateCacheAndLoadTightensPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CachePermissions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot()
        let monitor = makeMonitor(store: AccountStore(directory: root), fetchAntigravity: { data })
        let id = try #require(monitor.connectAntigravity())
        await (try #require(monitor.refresh(id))).value
        let folder = root.appendingPathComponent("snapshots")
        let file = folder.appendingPathComponent("\(id.uuidString).json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        for directory in [root, folder] {
            #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let restored = makeMonitor(store: monitor.store)
        #expect(restored.accounts[0].snapshot == data)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        for directory in [root, folder] {
            #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        await (try #require(monitor.refresh(id))).value
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        for directory in [root, folder] {
            #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        }
        monitor.disconnect(id)
        #expect(monitor.accounts.isEmpty)
        #expect(try monitor.store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func mixedProvidersUseOnlyTheirOwnFetchAdapters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let antigravity = CodexUsageSnapshot(
            identity: CodexIdentity(email: "antigravity@example.com"), windows: snapshot(percent: 79).windows,
            fetchedAt: now, source: .antigravityApp
        )
        let base = snapshot(percent: 23)
        let (monitor, profiles) = try codexAccounts(
            ["Codex"], root: root,
            fetch: { CodexUsageSnapshot(identity: $0.identity, windows: base.windows, fetchedAt: base.fetchedAt) },
            fetchAntigravity: { antigravity }
        )
        let antigravityID = try #require(monitor.connectAntigravity())

        for request in monitor.refreshAll() { await request.value }

        #expect(monitor.accounts.first(where: { $0.id == profiles[0].id })?.snapshot?.windows == base.windows)
        #expect(monitor.accounts.first(where: { $0.id == antigravityID })?.snapshot == antigravity)
    }

    @Test func identityFreeCLIReportDoesNotInheritTheCachedLocalAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = snapshot()
        let first = makeMonitor(store: AccountStore(directory: root), fetchAntigravity: { local })
        let id = try #require(first.connectAntigravity())
        await first.refresh(id)?.value
        let anonymous = CodexUsageSnapshot(
            identity: CodexIdentity(), windows: snapshot(percent: 72).windows,
            fetchedAt: now, source: .antigravityCLI
        )
        let restored = makeMonitor(store: first.store, fetchAntigravity: { anonymous })
        #expect(restored.accounts[0].snapshot?.identity.email == "test@example.com")

        await restored.refresh(id)?.value

        #expect(restored.accounts[0].snapshot == anonymous)
        #expect(restored.accounts[0].snapshot?.identity.email == nil)
    }

    @Test func cacheCannotCrossProviderEvenWithTheSameIDAndHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (monitor, profiles) = try codexAccounts(["Codex"], root: root, fetch: { snapshot(identity: $0.identity) })
        let id = profiles[0].id
        await monitor.refresh(id)?.value
        #expect(monitor.accounts[0].snapshot != nil)
        try monitor.store.save([AccountProfile(
            id: id, name: "Antigravity", homePath: profiles[0].homePath,
            isManaged: false, provider: .antigravity, authentication: .oauth,
            oauthIdentity: profiles[0].oauthIdentity
        )])

        let restored = makeMonitor(store: monitor.store)

        #expect(restored.accounts[0].snapshot == nil)
    }

    @Test func failureKeepsTheLastSuccessfulSnapshotAndBacksOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot(identity: credentials(1).identity)
        let responses = MonitorResponses(snapshot: data)
        let clock = now
        let (monitor, profiles) = try codexAccounts(
            ["계정"], root: root, fetch: { _ in try await responses.next() }, clock: { clock }
        )
        let id = profiles[0].id
        let first = try #require(monitor.refresh(id))
        await first.value
        await responses.fail()
        let second = try #require(monitor.refresh(id))
        await second.value

        #expect(monitor.accounts[0].snapshot == data)
        #expect(monitor.accounts[0].error != nil)
        #expect(monitor.accounts[0].isStale(at: now))
        #expect(monitor.refresh(id, manual: false) == nil)
        #expect(!monitor.accounts[0].isRefreshing)
    }

    @Test func failedReloginRestoresIdentityAndRefreshSucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Relogin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (monitor, profiles) = try codexAccounts(
            ["Original"], root: root,
            authenticate: { _ in throw CodexOAuthError.networkFailure },
            fetch: { snapshot(identity: $0.identity) }
        )
        let id = profiles[0].id
        await monitor.refresh(id)?.value
        await monitor.login(id, onURL: { _ in })?.value

        #expect(monitor.accounts[0].profile.oauthIdentity == profiles[0].oauthIdentity)
        #expect(try monitor.store.load()[0].oauthIdentity == profiles[0].oauthIdentity)
        let refresh = try #require(monitor.refresh(id, manual: false))
        await refresh.value
        #expect(monitor.accounts[0].snapshot == snapshot(identity: credentials(1).identity))
        #expect(monitor.accounts[0].error == nil)
    }

    @Test func postLoginFetchFailureRecordsBackoffWithoutRestoringOldIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LoginBackoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MonitorClock(now)
        let replacement = credentials(2)
        let (monitor, profiles) = try codexAccounts(
            ["Original"], root: root, authenticate: { _ in replacement },
            fetch: { _ in throw CodexOAuthError.networkFailure }, clock: { clock.now }
        )
        let id = profiles[0].id
        await monitor.login(id, onURL: { _ in })?.value
        #expect(monitor.accounts[0].profile.oauthIdentity == replacement.identity)
        #expect(try monitor.store.load()[0].oauthIdentity == replacement.identity)
        #expect(monitor.accounts[0].error != nil)
        clock.advance(by: 59)
        #expect(monitor.refresh(id, manual: false) == nil)
        clock.advance(by: 1)
        let retry = try #require(monitor.refresh(id, manual: false))
        await retry.value
        clock.advance(by: 119)
        #expect(monitor.refresh(id, manual: false) == nil)
        clock.advance(by: 1)
        await (try #require(monitor.refresh(id, manual: false))).value
    }

    @Test(arguments: [(1, 60.0), (2, 120.0), (3, 240.0), (4, 480.0),
                      (5, 900.0), (6, 900.0), (7, 900.0)])
    func failureBackoffScheduleReopensAtRetryAndManualRefreshBypassesIt(
        _ row: (Int, TimeInterval)
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Backoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MonitorClock(now)
        let responses = MonitorResponses(snapshot: snapshot(identity: credentials(1).identity))
        await responses.fail()
        let (monitor, profiles) = try codexAccounts(
            ["Account"], root: root, fetch: { _ in try await responses.next() }, clock: { clock.now }
        )
        let id = profiles[0].id
        // Each manual attempt must bypass the still-closed previous retry gate.
        for _ in 0..<row.0 {
            await (try #require(monitor.refresh(id))).value
        }
        clock.advance(by: row.1 - 1)
        #expect(monitor.refresh(id, manual: false) == nil)
        clock.advance(by: 1)
        await (try #require(monitor.refresh(id, manual: false))).value
        await responses.succeed()
        await (try #require(monitor.refresh(id))).value
        #expect(monitor.accounts[0].error == nil)
        // The old snapshot is older than the healthy gate, so only stale backoff
        // could block this automatic request after success.
        await (try #require(monitor.refresh(id, manual: false))).value
        await responses.fail()
        await (try #require(monitor.refresh(id))).value
        clock.advance(by: 59)
        #expect(monitor.refresh(id, manual: false) == nil)
        clock.advance(by: 1)
        await (try #require(monitor.refresh(id, manual: false))).value
    }

    @Test(arguments: [AccountProvider.codex, .claude, .antigravity])
    func healthyProviderGatesReopenAtBoundaryAndManualRefreshBypassesThem(
        _ provider: AccountProvider
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HealthyGate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MonitorClock(now)
        let data = snapshot(identity: credentials(1).identity)
        let monitor: UsageMonitor
        let id: UUID
        switch provider {
        case .codex:
            let result = try codexAccounts(
                ["Codex"], root: root, fetch: { _ in data }, clock: { clock.now }
            )
            monitor = result.0
            id = result.1[0].id
        case .antigravity:
            monitor = makeMonitor(
                store: AccountStore(directory: root), fetchAntigravity: { data }, clock: { clock.now }
            )
            id = try #require(monitor.connectAntigravity())
        case .claude:
            let keychain = ClaudeOAuthKeychain(service: "fixture.claude.monitor", security: OAuthFakeSecurity())
            let credentials = ClaudeOAuthCredentials(
                accessToken: "fixture-access", refreshToken: "fixture-refresh",
                expiresAt: now.addingTimeInterval(3600), accountID: "acct-1", email: "fixture@example.invalid"
            )
            let profile = AccountProfile(
                name: "Claude", homePath: root.path, isManaged: false, provider: .claude,
                authentication: .oauth, oauthIdentity: credentials.identity
            )
            try keychain.save(credentials, profileID: profile.id)
            let store = AccountStore(directory: root)
            try store.save([profile])
            monitor = makeMonitor(
                store: store, directClaude: ClaudeDirectClient(
                    keychain: keychain, authenticate: { _ in
                        Issue.record("Unexpected Claude login")
                        throw ClaudeOAuthError.signInRequired
                    }, renew: { _ in
                        Issue.record("Unexpected Claude renewal")
                        throw ClaudeOAuthError.signInRequired
                    }, fetch: { _ in data }, clock: { clock.now }
                ), clock: { clock.now }
            )
            id = profile.id
        }
        await (try #require(monitor.refresh(id))).value
        let interval: TimeInterval = provider == .codex ? 45 : 300
        clock.advance(by: interval - 1)
        #expect(monitor.refresh(id, manual: false) == nil)
        await (try #require(monitor.refresh(id))).value
        #expect(monitor.refresh(id, manual: false) == nil)
        clock.advance(by: 1)
        await (try #require(monitor.refresh(id, manual: false))).value
    }

    private func claudeAccount(
        root: URL, security: any AntigravityOAuthSecurity = OAuthFakeSecurity(),
        setupSecurity: (any AntigravityOAuthSecurity)? = nil,
        authenticate: @escaping @Sendable (@escaping @Sendable (URL) -> Void) async throws -> ClaudeOAuthCredentials = { _ in
            Issue.record("Unexpected Claude login")
            throw ClaudeOAuthError.signInRequired
        },
        fetch: @escaping @Sendable (ClaudeOAuthCredentials) async throws -> CodexUsageSnapshot,
        clock: @escaping @Sendable () -> Date
    ) throws -> (UsageMonitor, AccountProfile, ClaudeOAuthKeychain) {
        let service = "fixture.claude.monitor"
        let keychain = ClaudeOAuthKeychain(service: service, security: setupSecurity ?? security)
        let credentials = claudeCredentials(1)
        let profile = AccountProfile(
            name: "Claude", homePath: root.path, isManaged: false, provider: .claude,
            authentication: .oauth, oauthIdentity: credentials.identity
        )
        try keychain.save(credentials, profileID: profile.id)
        let store = AccountStore(directory: root)
        try store.save([profile])
        let monitor = makeMonitor(
            store: store, directClaude: ClaudeDirectClient(
                keychain: ClaudeOAuthKeychain(service: service, security: security),
                authenticate: authenticate, renew: { _ in
                    Issue.record("Unexpected Claude renewal")
                    throw ClaudeOAuthError.signInRequired
                }, fetch: fetch, clock: clock
            ), clock: clock
        )
        return (monitor, profile, keychain)
    }

    nonisolated private func claudeCredentials(_ index: Int) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: "fixture-access-\(index)", refreshToken: "fixture-refresh-\(index)",
            expiresAt: now.addingTimeInterval(86_400), accountID: "acct-\(index)",
            email: "claude-\(index)@example.invalid"
        )
    }

    @Test(arguments: [(TimeInterval?.some(1200), 1200.0), (nil, 300.0), (10, 300.0)])
    func claudeRateLimitWaitsForRetryAfterOrTheNormalInterval(_ row: (TimeInterval?, TimeInterval)) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RateLimit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MonitorClock(now)
        let (monitor, profile, _) = try claudeAccount(
            root: root, fetch: { _ in throw ClaudeClientError.rateLimited(retryAfter: row.0) }, clock: { clock.now }
        )
        await (try #require(monitor.refresh(profile.id))).value
        #expect(monitor.accounts[0].error != nil)

        clock.advance(by: row.1 - 1)
        #expect(monitor.refresh(profile.id, manual: false) == nil)
        clock.advance(by: 1)
        await (try #require(monitor.refresh(profile.id, manual: false))).value
    }

    @Test func clockMovingBackwardMakesTheSnapshotStaleAndDue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClockBack-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MonitorClock(now)
        let data = snapshot(identity: credentials(1).identity)
        let (monitor, profiles) = try codexAccounts(
            ["Codex"], root: root, fetch: { _ in data }, clock: { clock.now }
        )
        let id = profiles[0].id
        await (try #require(monitor.refresh(id))).value
        #expect(!monitor.accounts[0].isStale(at: clock.now))
        #expect(monitor.refresh(id, manual: false) == nil)

        clock.advance(by: -3600)

        #expect(monitor.accounts[0].isStale(at: clock.now))
        await (try #require(monitor.refresh(id, manual: false))).value
    }

    @Test(.timeLimit(.minutes(1)))
    func loginCancelledAfterCredentialsWereSavedKeepsProfileAndKeychainInSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LoginCommit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = OAuthFakeSecurity()
        let security = SaveSignalingSecurity(fake)
        let gate = MonitorGate<ClaudeOAuthCredentials>()
        var started = gate.started.makeAsyncIterator()
        let replacement = claudeCredentials(2)
        let (monitor, profile, keychain) = try claudeAccount(
            root: root, security: security, setupSecurity: fake, authenticate: { _ in await gate.wait() },
            fetch: { _ in
                Issue.record("A cancelled login must not fetch usage")
                throw ClaudeClientError.requestFailed
            }, clock: { Date(timeIntervalSince1970: 1_789_400_000) }
        )
        let id = profile.id
        let login = monitor.login(id, onURL: { _ in })
        let task = try #require(login)
        _ = await started.next()

        Task.detached { await gate.release(replacement) }
        // Keep the main actor busy until the direct login has saved and returned, so
        // the cancel below runs before the monitor's task resumes with the identity.
        #expect(blockUntilSaved(security))
        monitor.cancel(id)
        await task.value

        let saved = try #require(try keychain.load(profileID: id))
        // Proves the cancel landed after the flow committed; otherwise the race was not exercised.
        #expect(saved.identity == replacement.identity)
        #expect(monitor.accounts[0].profile.oauthIdentity == saved.identity)
        #expect(try monitor.store.load()[0].oauthIdentity == saved.identity)
        #expect(!monitor.accounts[0].isLoggingIn)
        #expect(!monitor.accounts[0].isRefreshing)
    }

    @Test func cacheRestoresOnlyTheSameProfileHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (monitor, profiles) = try codexAccounts(["계정"], root: root, fetch: { snapshot(identity: $0.identity) })
        let id = profiles[0].id
        await monitor.refresh(id)?.value
        let data = try #require(monitor.accounts[0].snapshot)
        let restored = makeMonitor(store: monitor.store)
        #expect(restored.accounts[0].snapshot == data)

        try monitor.store.save([AccountProfile(
            id: id, name: "변경한 계정", homePath: "/a/different/home", isManaged: false,
            authentication: .oauth, oauthIdentity: profiles[0].oauthIdentity
        )])
        let different = makeMonitor(store: monitor.store)
        #expect(different.accounts[0].snapshot == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentRefreshIsDeduplicatedAndLateRemovalCannotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MonitorGate<CodexUsageSnapshot>()
        var started = gate.started.makeAsyncIterator()
        let (monitor, profiles) = try codexAccounts(["계정"], root: root, fetch: { _ in await gate.wait() })
        let id = profiles[0].id
        let task = try #require(monitor.refresh(id))
        _ = await started.next()
        #expect(monitor.refresh(id) == nil)

        let removal = monitor.disconnect(id)
        var publishedLateSnapshot = false
        let observation = monitor.$accounts.sink { accounts in
            if accounts.first(where: { $0.id == id })?.snapshot != nil {
                publishedLateSnapshot = true
            }
        }
        defer { observation.cancel() }
        await gate.release(snapshot(identity: credentials(1).identity))
        await task.value
        await removal?.value

        #expect(!publishedLateSnapshot)
        #expect(monitor.accounts.isEmpty)
        #expect(try monitor.store.load().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("snapshots/\(id.uuidString).json").path
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func reauthenticationClearsThePreviousIdentityAndDiskSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MonitorGate<CodexOAuthCredentials>()
        var started = gate.started.makeAsyncIterator()
        let (monitor, profiles) = try codexAccounts(
            ["계정"], root: root, authenticate: { _ in await gate.wait() },
            fetch: { snapshot(identity: $0.identity) }
        )
        let id = profiles[0].id
        await monitor.refresh(id)?.value
        #expect(monitor.accounts[0].snapshot != nil)
        let pendingLogin = monitor.login(id, onURL: { _ in })
        let task = try #require(pendingLogin)
        _ = await started.next()

        #expect(monitor.accounts[0].snapshot == nil)
        #expect(monitor.accounts[0].profile.oauthIdentity == nil)
        #expect(monitor.accounts[0].isLoggingIn)
        let reloaded = makeMonitor(store: monitor.store)
        #expect(reloaded.accounts[0].snapshot == nil)
        #expect(reloaded.accounts[0].profile.oauthIdentity == nil)

        monitor.cancel(id)
        #expect(monitor.accounts[0].profile.oauthIdentity == profiles[0].oauthIdentity)
        #expect(try monitor.store.load()[0].oauthIdentity == profiles[0].oauthIdentity)
        // Start refresh before the cancelled login drains: it must capture the restored identity.
        let refresh = try #require(monitor.refresh(id))
        await gate.release(credentials(1))
        await task.value
        await refresh.value
        #expect(!monitor.accounts[0].isLoggingIn)
        #expect(monitor.accounts[0].snapshot == snapshot(identity: credentials(1).identity))
    }

    @Test func twoAccountsKeepIndependentUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (monitor, _) = try codexAccounts(["개인", "업무"], root: root, fetch: {
            snapshot(percent: $0.accountID == "acct-1" ? 12 : 86, identity: $0.identity)
        })
        for task in monitor.refreshAll() { await task.value }

        #expect(monitor.accounts[0].snapshot?.windows.first?.usedPercent == 12)
        #expect(monitor.accounts[1].snapshot?.windows.first?.usedPercent == 86)
        let restored = makeMonitor(store: monitor.store)
        #expect(restored.accounts[0].snapshot == monitor.accounts[0].snapshot)
        #expect(restored.accounts[1].snapshot == monitor.accounts[1].snapshot)
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulSecondLoginClearsProgressAndKeepsFirstAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let second = credentials(2)
        let (monitor, profiles) = try codexAccounts(
            ["첫 계정", "두 번째 계정"], root: root, authenticate: { _ in second },
            fetch: { snapshot(percent: $0.accountID == "acct-1" ? 42 : 100, identity: $0.identity) }
        )
        await monitor.refresh(profiles[0].id)?.value
        let firstData = try #require(monitor.accounts[0].snapshot)
        var publishedLoginStates: [Bool] = []
        let observation = monitor.$accounts.sink { accounts in
            if let account = accounts.first(where: { $0.id == profiles[1].id }) {
                publishedLoginStates.append(account.isLoggingIn)
            }
        }
        defer { observation.cancel() }
        let pending = monitor.login(profiles[1].id, onURL: { _ in })
        let task = try #require(pending)
        await task.value

        #expect(monitor.accounts[0].snapshot == firstData)
        #expect(monitor.accounts[1].snapshot?.identity == second.identity)
        #expect(monitor.accounts[1].snapshot?.windows.first?.usedPercent == 100)
        #expect(!monitor.accounts[1].isLoggingIn)
        #expect(!monitor.isWorking)
        #expect(monitor.notice == nil)
        #expect(publishedLoginStates.contains(true))
        #expect(publishedLoginStates.last == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedLoginJoinsPendingFlowWithoutLeavingFailureNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MonitorGate<CodexOAuthCredentials>()
        var started = gate.started.makeAsyncIterator()
        let (monitor, profiles) = try codexAccounts(
            ["두 번째 계정"], root: root, authenticate: { _ in await gate.wait() },
            fetch: { snapshot(identity: $0.identity) }
        )
        let id = profiles[0].id
        let pending = monitor.login(id, onURL: { _ in })
        let task = try #require(pending)
        _ = await started.next()
        let duplicate = monitor.login(id, onURL: { _ in })

        #expect(duplicate != nil)
        #expect(monitor.notice == nil)
        #expect(await gate.callCount == 1)
        #expect(monitor.rename(id, to: "Renamed during login"))
        await gate.release(credentials(2))
        await task.value

        #expect(monitor.accounts[0].snapshot == snapshot(identity: credentials(2).identity))
        #expect(monitor.accounts[0].profile.name == "Renamed during login")
        #expect(try monitor.store.load()[0].name == "Renamed during login")
        #expect(try monitor.store.load()[0].oauthIdentity == credentials(2).identity)
        #expect(!monitor.accounts[0].isLoggingIn)
        #expect(monitor.notice == nil)
    }

    @Test @MainActor func renamePersistsAliasAndRejectsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = makeMonitor(store: AccountStore(directory: root))
        let id = try #require(monitor.createCodexAccount(name: "Codex"))

        #expect(monitor.rename(id, to: "  업무용  "))
        #expect(monitor.accounts[0].profile.name == "업무용")
        #expect(try monitor.store.load()[0].name == "업무용")

        #expect(!monitor.rename(id, to: "   "))
        #expect(!monitor.rename(id, to: "업무용"))
        #expect(monitor.accounts[0].profile.name == "업무용")

        let restored = makeMonitor(store: monitor.store)
        #expect(restored.accounts[0].profile.name == "업무용")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelThenShutdownWaitsForAlreadyCancelledWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot(identity: credentials(1).identity)
        let gate = MonitorGate<CodexUsageSnapshot>()
        var started = gate.started.makeAsyncIterator()
        let (monitor, profiles) = try codexAccounts(["계정"], root: root, fetch: { _ in await gate.wait() })
        let id = profiles[0].id
        let request = try #require(monitor.refresh(id))
        _ = await started.next()
        monitor.cancel(id)

        let cleanup = CleanupObservation()
        // Subscribe before shutdown. Cleanup can run on the main actor only after
        // shutdown actually suspends to drain the cancelled operation.
        let observation = monitor.$isShuttingDown.sink { shuttingDown in
            guard shuttingDown else { return }
            Task { @MainActor in
                cleanup.released = true
                await gate.release(data)
            }
        }
        defer { observation.cancel() }
        await monitor.stopAndWait()

        #expect(cleanup.released)
        await request.value
        #expect(monitor.accounts[0].snapshot == nil)
    }

    @Test func moveTakesTargetPositionAndPersistsOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        let profiles = ["개인", "업무", "예비"].map {
            AccountProfile(name: $0, homePath: root.path, isManaged: false, authentication: .oauth)
        }
        try store.save(profiles)
        let monitor = makeMonitor(store: store)

        #expect(monitor.move(profiles[0].id, to: 2))
        #expect(monitor.accounts.map(\.profile.name) == ["업무", "예비", "개인"])
        #expect(try store.load().map(\.name) == ["업무", "예비", "개인"])

        #expect(monitor.move(profiles[2].id, to: 0))
        #expect(monitor.accounts.map(\.profile.name) == ["예비", "업무", "개인"])
        #expect(try store.load().map(\.name) == ["예비", "업무", "개인"])

        #expect(monitor.move(profiles[1].id, to: 1))
        #expect(monitor.accounts.map(\.profile.name) == ["예비", "업무", "개인"])
        #expect(!monitor.move(UUID(), to: 0))
        #expect(!monitor.move(profiles[0].id, to: 3))
    }
}

private struct UnexpectedMonitorSecurity: AntigravityOAuthSecurity {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        Issue.record("Unexpected Keychain load")
        return (errSecItemNotFound, nil)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        Issue.record("Unexpected Keychain add")
        return errSecAuthFailed
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        Issue.record("Unexpected Keychain update")
        return errSecAuthFailed
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        Issue.record("Unexpected Keychain delete")
        return errSecAuthFailed
    }
}

/// Signals each successful credential write so a test can tell when a login saved.
private final class SaveSignalingSecurity: AntigravityOAuthSecurity, @unchecked Sendable {
    private let base: OAuthFakeSecurity
    let saved = DispatchSemaphore(value: 0)

    init(_ base: OAuthFakeSecurity) { self.base = base }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) { base.copyMatching(query) }
    func add(_ attributes: [String: Any]) -> OSStatus {
        defer { saved.signal() }
        return base.add(attributes)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        defer { saved.signal() }
        return base.update(query, attributes: attributes)
    }
    func delete(_ query: [String: Any]) -> OSStatus { base.delete(query) }
}

/// Blocks the calling thread (the main actor) until a credential write, then gives the
/// direct login a moment to pass its post-save cancellation check and return.
private func blockUntilSaved(_ security: SaveSignalingSecurity) -> Bool {
    guard security.saved.wait(timeout: .now() + 10) == .success else { return false }
    Thread.sleep(forTimeInterval: 0.2)
    return true
}

private final class MonitorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

@MainActor
private final class CleanupObservation {
    var released = false
}

private actor MonitorResponses {
    let snapshot: CodexUsageSnapshot
    private var failing = false

    init(snapshot: CodexUsageSnapshot) { self.snapshot = snapshot }
    func fail() { failing = true }
    func succeed() { failing = false }
    func next() throws -> CodexUsageSnapshot {
        if failing { throw CodexOAuthError.networkFailure }
        return snapshot
    }

}

private actor MonitorGate<Value: Sendable> {
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Value, Never>?
    private(set) var callCount = 0

    init() {
        (started, signal) = AsyncStream.makeStream()
    }

    func wait() async -> Value {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            signal.yield(())
        }
    }

    func release(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
        signal.finish()
    }

}
