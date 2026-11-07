import Foundation

public struct CodexIdentity: Codable, Sendable, Equatable {
    public let email: String?
    public let planType: String?
    public let accountID: String?

    public init(email: String? = nil, planType: String? = nil, accountID: String? = nil) {
        self.email = email
        self.planType = planType
        self.accountID = accountID
    }
}

public struct CodexQuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Date?
    public let usageKnown: Bool
    public let resetDescription: String?

    /// Programmatic values must be finite and nonnegative. Values above 100 are valid.
    public init(id: String, label: String, usedPercent: Double, windowDurationMins: Int?, resetsAt: Date?,
                usageKnown: Bool = true, resetDescription: String? = nil) {
        precondition(usedPercent.isFinite && usedPercent >= 0)
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.usageKnown = usageKnown
        self.resetDescription = resetDescription
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPercent, windowDurationMins, resetsAt, usageKnown, resetDescription
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let percentage = try values.decode(Double.self, forKey: .usedPercent)
        guard percentage.isFinite, percentage >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .usedPercent, in: values, debugDescription: "Invalid quota percentage")
        }
        self.init(
            id: try values.decode(String.self, forKey: .id),
            label: try values.decode(String.self, forKey: .label),
            usedPercent: percentage,
            windowDurationMins: try values.decodeIfPresent(Int.self, forKey: .windowDurationMins),
            resetsAt: try values.decodeIfPresent(Date.self, forKey: .resetsAt),
            usageKnown: try values.decodeIfPresent(Bool.self, forKey: .usageKnown) ?? true,
            resetDescription: try values.decodeIfPresent(String.self, forKey: .resetDescription)
        )
    }
}

extension CodexQuotaWindow {
    public var isWeekly: Bool { windowDurationMins == 10_080 }

    /// Korean period label for a window length: 주간, N일, N시간, or N분.
    public static func durationLabel(minutes: Int) -> String {
        if minutes == 10_080 { return "주간" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }

    public func hasExpired(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

public enum UsageSource: String, Codable, Sendable {
    case antigravityApp
    case antigravityCLI
    case antigravityIDE
    case antigravityOAuth
    case codexOAuth
    /// Legacy Claude Code reuse; kept so older cached snapshots still decode.
    case claudeCode
    case claudeOAuth
}

public struct CodexUsageSnapshot: Codable, Sendable, Equatable {
    public let identity: CodexIdentity
    public let windows: [CodexQuotaWindow]
    public let credits: String?
    public let fetchedAt: Date
    public let ordinaryUsageAllowed: Bool?
    public let source: UsageSource?

    public init(identity: CodexIdentity, windows: [CodexQuotaWindow], credits: String? = nil,
                fetchedAt: Date = Date(), ordinaryUsageAllowed: Bool? = nil, source: UsageSource? = nil) {
        self.identity = identity
        self.windows = windows
        self.credits = credits
        self.fetchedAt = fetchedAt
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.source = source
    }
}
