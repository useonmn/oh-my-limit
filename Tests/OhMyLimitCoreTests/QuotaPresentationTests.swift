import Foundation
import Testing
@testable import OhMyLimitCore

struct QuotaPresentationTests {
    @Test(arguments: [
        (10_080, true),
        (300, false),
        (1_440, false),
        (nil, false),
    ])
    func weeklyWindow(duration: Int?, expected: Bool) {
        let window = CodexQuotaWindow(
            id: "quota",
            label: "Quota",
            usedPercent: 45,
            windowDurationMins: duration,
            resetsAt: nil
        )

        #expect(window.isWeekly == expected)
    }

    @Test(arguments: [
        (-1.0, true),
        (0.0, true),
        (1.0, false),
        (nil, false),
    ])
    func expiration(offset: TimeInterval?, expected: Bool) {
        let now = Date(timeIntervalSince1970: 1_789_400_000)
        let window = CodexQuotaWindow(
            id: "quota",
            label: "Quota",
            usedPercent: 45,
            windowDurationMins: nil,
            resetsAt: offset.map { now.addingTimeInterval($0) }
        )

        #expect(window.hasExpired(at: now) == expected)
    }
}
