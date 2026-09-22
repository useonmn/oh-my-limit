import Combine
import Foundation
import Testing
@testable import OhMyLimitCore

@MainActor
struct UsageMonitorTests {
    private let now = Date(timeIntervalSince1970: 1_789_400_000)

    private func snapshot(percent: Double = 34) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            identity: CodexIdentity(email: "test@example.com", planType: "plus"),
            windows: [CodexQuotaWindow(
                id: "codex.primary", label: "주간", usedPercent: percent,
                windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(3600)
            )], fetchedAt: now
        )
    }

    @Test(arguments: [(100.0, 3.0), (42.0, 99.0)])
    func codexSummaryUsesMainWeeklyQuotaInsteadOfReserve(_ percentages: (Double, Double)) throws {
        let data = Data("""
        {"rateLimitsByLimitId":{
          "base_model_inference":{"limitName":"gpt-reserve","primary":{"usedPercent":\(percentages.1),"windowDurationMins":10080}},
          "codex":{"primary":{"usedPercent":\(percentages.0),"windowDurationMins":10080}},
          "codex_bengalfox":{"secondary":{"usedPercent":0,"windowDurationMins":10080}}
        }}
        """.utf8)
        let snapshot = try CodexResponseParser.usage(from: data, identity: CodexIdentity())
        let state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false),
            snapshot: snapshot
        )

        #expect(state.menuWindow?.id == "codex.primary")
        #expect(state.menuWindow?.usedPercent == percentages.0)
    }

    @Test func codexSummaryPrefersMainShortWindowOverReserveWeekly() throws {
        let data = Data(#"""
        {"rateLimitsByLimitId":{
          "base_model_inference":{"primary":{"usedPercent":3,"windowDurationMins":10080}},
          "codex":{"primary":{"usedPercent":55,"windowDurationMins":300}}
        }}
        """#.utf8)
        let state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false),
            snapshot: try CodexResponseParser.usage(from: data, identity: CodexIdentity())
        )

        #expect(state.menuWindow?.id == "codex.primary")
        #expect(state.menuWindow?.usedPercent == 55)
    }

    @Test func codexSummaryDoesNotSubstituteReserveWhenMainQuotaIsUnavailable() {
        let state = AccountState(
            profile: AccountProfile(name: "Codex", homePath: "/fixture", isManaged: false),
            snapshot: CodexUsageSnapshot(identity: CodexIdentity(), windows: [
                CodexQuotaWindow(id: "base_model_inference.primary", label: "gpt-reserve",
                    usedPercent: 3, windowDurationMins: 10_080, resetsAt: nil),
                CodexQuotaWindow(id: "codex.primary", label: "주간",
                    usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil, usageKnown: false),
                CodexQuotaWindow(id: "codex_bengalfox.secondary", label: "Spark",
                    usedPercent: 0, windowDurationMins: 10_080, resetsAt: nil)
            ])
        )

        #expect(state.menuWindow == nil)
    }

    @Test func antigravityLoginNeverStartsCodexAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        let profile = AccountProfile(
            name: "Antigravity", homePath: "/local/user", isManaged: false, provider: .antigravity
        )
        try store.save([profile])
        let data = snapshot()
        let monitor = UsageMonitor(
            store: store, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in data },
            authenticate: { _, _, _ in
                Issue.record("Antigravity must not invoke the Codex authentication adapter")
                return data.identity
            }
        )

        let request = monitor.login(profile.id, onURL: { _ in })
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

    @Test func antigravityRefreshNeedsNoCodexAndRestoresItsOwnCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = CodexUsageSnapshot(
            identity: CodexIdentity(email: "local@example.com"), windows: snapshot().windows,
            fetchedAt: now, source: .antigravityApp
        )
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: nil, fetchAntigravity: { data }
        )
        let id = try #require(monitor.connectAntigravity())
        #expect(monitor.connectAntigravity() == id)

        let request = try #require(monitor.refresh(id))
        await request.value

        #expect(monitor.accounts.count == 1)
        #expect(monitor.accounts[0].snapshot == data)
        #expect(monitor.accounts[0].error == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles").path))
        let restored = UsageMonitor(store: monitor.store, executableURL: nil)
        #expect(restored.accounts[0].profile.provider == .antigravity)
        #expect(restored.accounts[0].snapshot == data)
    }

    @Test func mixedProvidersUseOnlyTheirOwnFetchAdapters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = snapshot(percent: 23)
        let antigravity = CodexUsageSnapshot(
            identity: CodexIdentity(email: "antigravity@example.com"), windows: snapshot(percent: 79).windows,
            fetchedAt: now, source: .antigravityApp
        )
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in codex }, fetchAntigravity: { antigravity }
        )
        let codexID = try #require(monitor.createAccount(name: "Codex"))
        let antigravityID = try #require(monitor.connectAntigravity())

        for request in monitor.refreshAll() { await request.value }

        #expect(monitor.accounts.first(where: { $0.id == codexID })?.snapshot == codex)
        #expect(monitor.accounts.first(where: { $0.id == antigravityID })?.snapshot == antigravity)
    }

    @Test func identityFreeCLIReportDoesNotInheritTheCachedLocalAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = snapshot()
        let first = UsageMonitor(
            store: AccountStore(directory: root), executableURL: nil, fetchAntigravity: { local }
        )
        let id = try #require(first.connectAntigravity())
        await first.refresh(id)?.value
        let anonymous = CodexUsageSnapshot(
            identity: CodexIdentity(), windows: snapshot(percent: 72).windows,
            fetchedAt: now, source: .antigravityCLI
        )
        let restored = UsageMonitor(store: first.store, executableURL: nil, fetchAntigravity: { anonymous })
        #expect(restored.accounts[0].snapshot?.identity.email == "test@example.com")

        await restored.refresh(id)?.value

        #expect(restored.accounts[0].snapshot == anonymous)
        #expect(restored.accounts[0].snapshot?.identity.email == nil)
    }

    @Test func cacheCannotCrossProviderEvenWithTheSameIDAndHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot()
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in data }
        )
        let id = try #require(monitor.createAccount(name: "Codex"))
        await monitor.refresh(id)?.value
        let original = monitor.accounts[0].profile
        try monitor.store.save([AccountProfile(
            id: id, name: "Antigravity", homePath: original.homePath,
            isManaged: false, provider: .antigravity
        )])

        let restored = UsageMonitor(store: monitor.store, executableURL: nil)

        #expect(restored.accounts[0].snapshot == nil)
    }

    @Test(arguments: [299.0, 300.0])
    func antigravityAutomaticRefreshUsesFiveMinuteCadence(_ age: TimeInterval) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = now
        let data = CodexUsageSnapshot(
            identity: CodexIdentity(), windows: snapshot().windows, fetchedAt: now.addingTimeInterval(-age)
        )
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: nil,
            fetchAntigravity: { data }, clock: { clock }
        )
        let id = try #require(monitor.connectAntigravity())
        await monitor.refresh(id)?.value

        let automatic = monitor.refresh(id, manual: false)
        await automatic?.value

        #expect((automatic != nil) == (age >= 300))
        #expect(!monitor.accounts[0].isStale(at: now))
    }

    @Test func failureKeepsTheLastSuccessfulSnapshotAndBacksOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot()
        let responses = MonitorResponses(snapshot: data)
        let clock = now
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in try await responses.next() }, clock: { clock }
        )
        let id = try #require(monitor.createAccount(name: "계정"))
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

    @Test func cacheRestoresOnlyTheSameProfileHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot()
        let store = AccountStore(directory: root)
        let monitor = UsageMonitor(
            store: store, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in data }
        )
        let id = try #require(monitor.createAccount(name: "계정"))
        await monitor.refresh(id)?.value
        let restored = UsageMonitor(store: store, executableURL: nil)
        #expect(restored.accounts[0].snapshot == data)

        try store.save([AccountProfile(id: id, name: "변경한 계정", homePath: "/a/different/home", isManaged: true)])
        let different = UsageMonitor(store: store, executableURL: nil)
        #expect(different.accounts[0].snapshot == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentRefreshIsDeduplicatedAndLateRemovalCannotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MonitorGate<CodexUsageSnapshot>()
        var started = gate.started.makeAsyncIterator()
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in await gate.wait() }
        )
        let id = try #require(monitor.createAccount(name: "계정"))
        let task = try #require(monitor.refresh(id))
        _ = await started.next()
        #expect(monitor.refresh(id) == nil)

        monitor.disconnect(id)
        await gate.release(snapshot())
        await task.value

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
        let data = snapshot()
        let gate = MonitorGate<CodexIdentity>()
        var started = gate.started.makeAsyncIterator()
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in data },
            authenticate: { _, _, _ in await gate.wait() }
        )
        let id = try #require(monitor.createAccount(name: "계정"))
        await monitor.refresh(id)?.value
        let pendingLogin = monitor.login(id, onURL: { _ in })
        let task = try #require(pendingLogin)
        _ = await started.next()

        #expect(monitor.accounts[0].snapshot == nil)
        #expect(monitor.accounts[0].isLoggingIn)
        let reloaded = UsageMonitor(store: monitor.store, executableURL: nil)
        #expect(reloaded.accounts[0].snapshot == nil)

        monitor.cancel(id)
        await gate.release(CodexIdentity())
        await task.value
        #expect(!monitor.accounts[0].isLoggingIn)
        #expect(monitor.accounts[0].snapshot == nil)
    }

    @Test func missingCLIDoesNotReplaceCachedUsageWithZero() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot()
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in data }
        )
        let id = try #require(monitor.createAccount(name: "계정"))
        await monitor.refresh(id)?.value
        let unavailable = UsageMonitor(store: monitor.store, executableURL: nil)
        #expect(unavailable.refresh(id) == nil)
        #expect(unavailable.accounts[0].snapshot == data)
        #expect(unavailable.accounts[0].error != nil)
    }

    @Test func twoAccountsKeepIndependentUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        let first = try store.createManagedProfile(name: "개인")
        let second = try store.createManagedProfile(name: "업무")
        try store.save([first, second])
        let firstData = snapshot(percent: 12)
        let secondData = snapshot(percent: 86)
        let monitor = UsageMonitor(
            store: store, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, home in home == first.homeURL ? firstData : secondData }
        )
        for task in monitor.refreshAll() { await task.value }

        #expect(monitor.accounts[0].snapshot == firstData)
        #expect(monitor.accounts[1].snapshot == secondData)
        let restored = UsageMonitor(store: store, executableURL: nil)
        #expect(restored.accounts[0].snapshot == firstData)
        #expect(restored.accounts[1].snapshot == secondData)
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulSecondLoginClearsProgressAndKeepsFirstAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        let first = try store.createManagedProfile(name: "첫 계정")
        let second = try store.createManagedProfile(name: "두 번째 계정")
        try store.save([first, second])
        let firstData = snapshot(percent: 42)
        let secondData = CodexUsageSnapshot(
            identity: CodexIdentity(email: "second@example.com", planType: "prolite"),
            windows: snapshot(percent: 100).windows, fetchedAt: now
        )
        let monitor = UsageMonitor(
            store: store, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, home in home == first.homeURL ? firstData : secondData },
            authenticate: { _, _, _ in secondData.identity }
        )
        await monitor.refresh(first.id)?.value
        var publishedLoginStates: [Bool] = []
        let observation = monitor.$accounts.sink { accounts in
            if let account = accounts.first(where: { $0.id == second.id }) {
                publishedLoginStates.append(account.isLoggingIn)
            }
        }
        defer { observation.cancel() }
        let pending = monitor.login(second.id, onURL: { _ in })
        let task = try #require(pending)
        await task.value

        #expect(monitor.accounts[0].snapshot == firstData)
        #expect(monitor.accounts[1].snapshot == secondData)
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
        let data = snapshot()
        let gate = MonitorGate<CodexIdentity>()
        var started = gate.started.makeAsyncIterator()
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in data },
            authenticate: { _, _, _ in await gate.wait() }
        )
        let id = try #require(monitor.createAccount(name: "두 번째 계정"))
        let pending = monitor.login(id, onURL: { _ in })
        let task = try #require(pending)
        _ = await started.next()
        let duplicate = monitor.login(id, onURL: { _ in })

        #expect(duplicate != nil)
        #expect(monitor.notice == nil)
        #expect(await gate.callCount == 1)
        await gate.release(data.identity)
        await task.value

        #expect(monitor.accounts[0].snapshot == data)
        #expect(!monitor.accounts[0].isLoggingIn)
        #expect(monitor.notice == nil)
    }

    @Test @MainActor func renamePersistsAliasAndRejectsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = UsageMonitor(store: AccountStore(directory: root), executableURL: nil)
        let id = try #require(monitor.createCodexAccount(name: "Codex"))

        #expect(monitor.rename(id, to: "  업무용  "))
        #expect(monitor.accounts[0].profile.name == "업무용")
        #expect(try monitor.store.load()[0].name == "업무용")

        #expect(!monitor.rename(id, to: "   "))
        #expect(!monitor.rename(id, to: "업무용"))
        #expect(monitor.accounts[0].profile.name == "업무용")

        let restored = UsageMonitor(store: monitor.store, executableURL: nil)
        #expect(restored.accounts[0].profile.name == "업무용")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelThenShutdownWaitsForAlreadyCancelledWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = snapshot()
        let gate = MonitorGate<CodexUsageSnapshot>()
        var started = gate.started.makeAsyncIterator()
        let monitor = UsageMonitor(
            store: AccountStore(directory: root), executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            fetch: { _, _ in await gate.wait() }
        )
        let id = try #require(monitor.createAccount(name: "계정"))
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
        let profiles = ["개인", "업무", "예비"].enumerated().map {
            AccountProfile(name: $0.element, homePath: "/codex/\($0.offset)", isManaged: false)
        }
        try store.save(profiles)
        let monitor = UsageMonitor(store: store, executableURL: nil)

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

@MainActor
private final class CleanupObservation {
    var released = false
}

private actor MonitorResponses {
    let snapshot: CodexUsageSnapshot
    private var failing = false

    init(snapshot: CodexUsageSnapshot) { self.snapshot = snapshot }
    func fail() { failing = true }
    func next() throws -> CodexUsageSnapshot {
        if failing { throw CodexClientError.notLoggedIn }
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
