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
}
