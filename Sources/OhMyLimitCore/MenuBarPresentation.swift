import Foundation

public enum AccountUsageDisplay {
    public static func value(for state: AccountState, at now: Date) -> String {
        guard let window = state.menuWindow, !window.hasExpired(at: now) else { return "—" }
        return (state.isStale(at: now) ? "~" : "") + String(format: "%.0f%%", window.usedPercent)
    }
}

public struct MenuBarEntry: Equatable, Sendable {
    public let provider: AccountProvider
    public let text: String
}

public enum MenuBarPresentation {
    public static func entries(for states: [AccountState], at now: Date, limit: Int) -> [MenuBarEntry] {
        let visible = states.prefix(limit)
        return visible.enumerated().map { offset, state in
            let overflow = offset == visible.count - 1 && states.count > visible.count
                ? " +\(states.count - visible.count)" : ""
            return MenuBarEntry(provider: state.profile.provider,
                                text: AccountUsageDisplay.value(for: state, at: now) + overflow)
        }
    }

    public static func fit(_ states: [AccountState], at now: Date, limit: Int, maxWidth: Double,
                           width: ([MenuBarEntry]) -> Double) -> [MenuBarEntry] {
        for count in stride(from: limit, to: 1, by: -1) {
            let candidate = entries(for: states, at: now, limit: count)
            if width(candidate) <= maxWidth { return candidate }
        }
        return entries(for: states, at: now, limit: 1)
    }

    public static func summaryLines(for states: [AccountState], at now: Date) -> String {
        states.map { state in
            var text = AccountUsageDisplay.value(for: state, at: now)
            if text != "—", let window = state.menuWindow, window.isWeekly, let resetsAt = window.resetsAt {
                text += "·" + resetCountdown(until: resetsAt, from: now)
            }
            return "\(state.profile.name) · \(state.profile.provider.displayName): \(text)"
        }.joined(separator: "\n")
    }

    public static func tooltip(for states: [AccountState], at now: Date) -> String {
        guard !states.isEmpty else { return "연결된 계정 없음" }
        return "사용률 · 주간 우선 · ~ 표시는 마지막 확인값 · % 뒤는 주간 초기화까지\n"
            + summaryLines(for: states, at: now)
    }

    public static func accessibilityLabel(for states: [AccountState], at now: Date) -> String {
        guard !states.isEmpty else { return "Oh My Limit, 연결된 계정 없음" }
        return "Oh My Limit\n" + summaryLines(for: states, at: now)
    }

    /// Compact countdown for the menu bar: "3d15h", "15h", or "42m".
    static func resetCountdown(until date: Date, from now: Date) -> String {
        let minutes = max(1, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }
}
