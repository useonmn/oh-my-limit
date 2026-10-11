import Foundation
import OhMyLimitCore

enum AccountUsageDisplay {
    static func value(for state: AccountState, at now: Date) -> String {
        guard let window = state.menuWindow,
              !(window.resetsAt.map { $0 <= now } ?? false) else { return "—" }
        return (state.isStale(at: now) ? "~" : "") + String(format: "%.0f%%", window.usedPercent)
    }
}
