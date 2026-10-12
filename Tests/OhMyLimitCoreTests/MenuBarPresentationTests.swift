import Foundation
import Testing
@testable import OhMyLimitCore

struct MenuBarPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_789_400_000)

    private static func window(id: String = "codex.weekly", used: Double = 45, minutes: Int? = 10_080,
                               resetsAt: Date? = now.addingTimeInterval(3 * 86_400 + 15 * 3_600),
                               known: Bool = true) -> CodexQuotaWindow {
        CodexQuotaWindow(id: id, label: "주간", usedPercent: used, windowDurationMins: minutes,
                         resetsAt: resetsAt, usageKnown: known)
    }

    private static func state(name: String = "A", windows: [CodexQuotaWindow]? = [window()],
                              fetchedAt: Date = now) -> AccountState {
        let profile = AccountProfile(name: name, homePath: "/tmp/\(name)", isManaged: true, provider: .codex)
        let snapshot = windows.map { CodexUsageSnapshot(identity: CodexIdentity(), windows: $0, fetchedAt: fetchedAt) }
        return AccountState(profile: profile, snapshot: snapshot)
    }

    @Test func valueRendersDashForUnknownStates() {
        let unknown = Self.state(windows: [Self.window(known: false)])
        #expect(unknown.menuWindow == nil)
        let cases: [(AccountState, String)] = [
            (Self.state(windows: nil), "—"),
            (unknown, "—"),
            (Self.state(windows: [Self.window(resetsAt: Self.now.addingTimeInterval(-1))]), "—"),
            (Self.state(fetchedAt: Self.now.addingTimeInterval(-600)), "~45%"),
            (Self.state(), "45%"),
        ]
        for (state, expected) in cases {
            #expect(AccountUsageDisplay.value(for: state, at: Self.now) == expected)
        }
    }

    @Test func emptyStatesHaveExplicitTooltipAndAccessibilityLabel() {
        #expect(MenuBarPresentation.accessibilityLabel(for: [], at: Self.now) == "Oh My Limit, 연결된 계정 없음")
        #expect(MenuBarPresentation.tooltip(for: [], at: Self.now) == "연결된 계정 없음")
    }

    @Test func tooltipAndAccessibilityLabelWrapSummaryLines() {
        let states = [Self.state()]
        let lines = MenuBarPresentation.summaryLines(for: states, at: Self.now)
        #expect(MenuBarPresentation.tooltip(for: states, at: Self.now)
            == "사용률 · 주간 우선 · ~ 표시는 마지막 확인값 · % 뒤는 주간 초기화까지\n" + lines)
        #expect(MenuBarPresentation.accessibilityLabel(for: states, at: Self.now) == "Oh My Limit\n" + lines)
    }

    @Test func entriesShowFirstAccountsAndOverflowCount() {
        let cases: [(Int, [String])] = [
            (0, []),
            (2, ["45%", "45%"]),
            (3, ["45%", "45%", "45%"]),
            (5, ["45%", "45%", "45% +2"]),
        ]
        for (count, texts) in cases {
            let states = (0..<count).map { Self.state(name: "A\($0)") }
            let entries = MenuBarPresentation.entries(for: states, at: Self.now, limit: 3)
            #expect(entries.map(\.text) == texts)
            #expect(entries.allSatisfy { $0.provider == .codex })
        }
    }

    @Test func resetCountdownIsCompact() {
        let cases: [(TimeInterval, String)] = [
            (42 * 60, "42m"),
            (15 * 3_600, "15h"),
            (3 * 86_400 + 15 * 3_600, "3d15h"),
            (2 * 86_400, "2d"),
            (-3_600, "1m"),
        ]
        for (offset, expected) in cases {
            #expect(MenuBarPresentation.resetCountdown(until: Self.now.addingTimeInterval(offset), from: Self.now) == expected)
        }
    }

    @Test func summaryLinesAppendCountdownOnlyForWeeklyWindows() {
        let weekly = Self.state(name: "W")
        let session = Self.state(name: "S", windows: [Self.window(id: "codex.session", minutes: 300)])
        let provider = AccountProvider.codex.displayName
        #expect(MenuBarPresentation.summaryLines(for: [weekly, session], at: Self.now)
            == "W · \(provider): 45%·3d15h\nS · \(provider): 45%")
    }

    @Test func fitDropsAccountsUntilWidthFits() {
        let states = (0..<5).map { Self.state(name: "A\($0)") }
        let entries = MenuBarPresentation.fit(states, at: Self.now, limit: 3, maxWidth: 240) {
            Double($0.count) * 100
        }
        #expect(entries.map(\.text) == ["45%", "45% +3"])
        let tooNarrow = MenuBarPresentation.fit(states, at: Self.now, limit: 3, maxWidth: 10) {
            Double($0.count) * 100
        }
        #expect(tooNarrow.map(\.text) == ["45% +4"])
    }
}
