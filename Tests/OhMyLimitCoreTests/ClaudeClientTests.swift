import Foundation
import Testing
@testable import OhMyLimitCore

struct ClaudeClientTests {
    @Test func newerLimitsPreserveWeeklyAndModelBoundaries() throws {
        let data = Data(#"""
        {"limits":[
          {"kind":"session","percent":0,"resets_at":"2026-09-23T08:10:00.126147+00:00"},
          {"kind":"weekly_all","percent":62,"resets_at":"2026-09-28T06:00:00Z"},
          {"kind":"weekly_scoped","percent":100,"scope":{"model":{"display_name":"Opus"}}},
          {"kind":"other","percent":99}
        ]}
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data, plan: "max")
        #expect(snapshot.windows.map(\.id) == ["claude.session", "claude.weekly", "claude.model.Opus"])
        #expect(snapshot.windows.map(\.usedPercent) == [0, 62, 100])
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.windows[1].resetsAt != nil)
        #expect(snapshot.identity.planType == "max")
        let profile = AccountProfile(name: "Claude", homePath: "/tmp/claude", isManaged: false, provider: .claude)
        #expect(AccountState(profile: profile, snapshot: snapshot).menuWindow?.id == "claude.weekly")
    }

    @Test func legacyWindowsDoNotInventMissingUsage() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":105,"resets_at":null},"seven_day":{"utilization":null}}
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data)
        #expect(snapshot.windows[0].usedPercent == 105)
        #expect(snapshot.windows[0].usageKnown)
        #expect(!snapshot.windows[1].usageKnown)
        let profile = AccountProfile(name: "Claude", homePath: "/tmp/claude", isManaged: false, provider: .claude)
        #expect(AccountState(profile: profile, snapshot: snapshot).menuWindow?.id == "claude.session")
        #expect(throws: ClaudeClientError.self) {
            try ClaudeUsageParser.parse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
        }
    }

    @Test func unknownNewWeeklyQuotaUsesKnownLegacyWeeklyValue() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_all","percent":null}],"seven_day":{"utilization":44}}"#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == "claude.weekly")
        #expect(snapshot.windows[0].usedPercent == 44)
        #expect(snapshot.windows[0].usageKnown)
    }

    @Test func expiredAccessTokenWithLiveRefreshTokenIsNotALogout() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func credentials(_ oauth: String) throws -> ClaudeClient.Credentials {
            try #require(ClaudeClient.decodeCredentials(Data(#"{"claudeAiOauth":{"accessToken":"a",\#(oauth)}}"#.utf8), now: now))
        }
        let expired = #""expiresAt":1999000000"#
        let waiting = try credentials(#"\#(expired),"refreshToken":"r","refreshTokenExpiresAt":2001000000"#)
        #expect(throws: ClaudeClientError.awaitingClaudeCodeRefresh) { try waiting.checkUsable(now: now) }
        let noExpiry = try credentials(#"\#(expired),"refreshToken":"r""#)
        #expect(throws: ClaudeClientError.awaitingClaudeCodeRefresh) { try noExpiry.checkUsable(now: now) }
        for dead in [#""refreshToken":"""#, #""refreshToken":"r","refreshTokenExpiresAt":1999000000"#, #""scopes":[]"#] {
            let loggedOut = try credentials("\(expired),\(dead)")
            #expect(throws: ClaudeClientError.expired) { try loggedOut.checkUsable(now: now) }
        }
        try credentials(#""expiresAt":2001000000"#).checkUsable(now: now)
    }

    @Test func loginCommandRunsOfficialCLIAndCleansItselfUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Claude's CLI")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        let stub = "#!/bin/sh\n[ \"$1\" = auth ] && [ \"$2\" = login ] && [ \"$3\" = --claudeai ] && [ \"$#\" -eq 3 ] && [ \"$CLAUDE_CONFIG_DIR\" = \"$EXPECTED_CLAUDE_CONFIG_DIR\" ]\n"
        try Data(stub.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = root.appendingPathComponent("Claude's config")
        let script = try ClaudeClient.prepareLoginCommand(in: root.appendingPathComponent("commands"),
                                                           executableURL: executable, configDirectory: config)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["EXPECTED_CLAUDE_CONFIG_DIR": config.path]) { _, expected in expected }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: script.path))
    }

    @Test @MainActor func localClaudeSurvivesRestartWithoutCodexAndKeepsOwnQuota() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = try ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":24},"seven_day":{"utilization":55}}"#.utf8))
        let monitor = UsageMonitor(store: AccountStore(directory: root.appendingPathComponent("app")),
                                   executableURL: nil, fetchClaude: { _, _ in data })
        let id = try #require(monitor.connectClaude(home: home))
        #expect(monitor.connectClaude(home: home) == id)
        await monitor.refresh(id)?.value
        #expect(monitor.accounts[0].menuWindow?.usedPercent == 55)
        let restored = UsageMonitor(store: monitor.store, executableURL: nil, fetchClaude: { _, _ in data })
        #expect(restored.accounts[0].profile.provider == .claude)
        #expect(restored.accounts[0].snapshot == data)
        #expect(restored.accounts[0].menuWindow?.id == "claude.weekly")
        #expect(restored.login(id, onURL: { _ in }) == nil)
        #expect(restored.accounts[0].snapshot == data)
    }
    @Test @MainActor func deniedKeychainRequiresExplicitAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let snapshot = try ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":39}}"#.utf8))
        let monitor = UsageMonitor(store: AccountStore(directory: root.appendingPathComponent("app")),
                                   executableURL: nil, fetchClaude: { _, allowInteraction in
            guard allowInteraction else { throw ClaudeClientError.keychainUnavailable }
            return snapshot
        })
        let id = try #require(monitor.connectClaude(home: home))
        await monitor.refresh(id)?.value
        #expect(monitor.accounts[0].needsKeychainAccess)
        #expect(monitor.accounts[0].snapshot == nil)
        await monitor.authorizeKeychain(id)?.value
        #expect(monitor.accounts[0].snapshot == snapshot)
        #expect(!monitor.accounts[0].needsKeychainAccess)
    }

}
