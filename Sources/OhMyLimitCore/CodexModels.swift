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

public enum UsageSource: String, Codable, Sendable {
    case antigravityApp
    case antigravityCLI
    case antigravityIDE
    case antigravityOAuth
    case codexOAuth
    case claudeCode
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

public enum CodexClientError: Error, LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case launchFailed
    case timedOut
    case malformedProtocol
    case processExited
    case outputLimitExceeded
    case serverError(code: Int)
    case invalidLoginURL
    case loginFailed

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "ChatGPT 계정 로그인이 필요합니다."
        case .launchFailed: "Codex 실행 파일을 시작할 수 없습니다. 설치 및 실행 권한을 확인해 주세요."
        case .timedOut: "Codex 응답 시간이 초과되었습니다. 다시 시도해 주세요."
        case .malformedProtocol: "Codex 응답 형식이 올바르지 않습니다. CLI를 업데이트해 주세요."
        case .processExited: "Codex 연결이 예기치 않게 종료되었습니다."
        case .outputLimitExceeded: "Codex 응답이 허용된 크기를 초과했습니다."
        case .serverError(let code): "Codex 서버 요청에 실패했습니다 (코드 \(code))."
        case .invalidLoginURL: "공식 로그인 주소를 확인할 수 없습니다."
        case .loginFailed: "ChatGPT 로그인을 완료하지 못했습니다. 다시 시도해 주세요."
        }
    }
}

// Decode only the structured fields this app consumes. Never expose server error text.
enum CodexResponseParser {
    static func identity(from data: Data) throws -> CodexIdentity {
        let response = try decode(AccountResponse.self, data)
        guard let account = response.account, account.type == "chatgpt" else {
            throw CodexClientError.notLoggedIn
        }
        return CodexIdentity(email: account.email, planType: account.planType,
                             accountID: account.accountId ?? account.account_id ?? response.accountId ?? response.account_id)
    }

    static func usage(from data: Data, identity: CodexIdentity) throws -> CodexUsageSnapshot {
        let response = try decode(UsageResponse.self, data)
        let buckets: [(String, Bucket)]
        if let multiple = response.rateLimitsByLimitId {
            buckets = multiple.keys.sorted().map { ($0, multiple[$0]!) }
        } else if let legacy = response.rateLimits {
            buckets = [(legacy.limitId ?? "codex", legacy)]
        } else {
            throw CodexClientError.malformedProtocol
        }
        var windows: [CodexQuotaWindow] = []
        for (key, bucket) in buckets {
            for (slot, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                guard window.usedPercent.isFinite, window.usedPercent >= 0,
                      window.resetsAt.map({ $0.isFinite }) ?? true,
                      window.windowDurationMins.map({ $0 > 0 }) ?? true else {
                    throw CodexClientError.malformedProtocol
                }
                let label: String
                if key == "codex" {
                    switch window.windowDurationMins {
                    case 300: label = "5시간"
                    case 10_080: label = "주간"
                    default: label = bucket.limitName ?? key
                    }
                } else {
                    label = bucket.limitName ?? key
                }
                windows.append(CodexQuotaWindow(
                    id: "\(key).\(slot)", label: label, usedPercent: window.usedPercent,
                    windowDurationMins: window.windowDurationMins,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
                ))
            }
        }
        // Workspace credits belong to the default bucket; don't add duplicate balances.
        let defaultBucket = buckets.first(where: { $0.0 == "codex" })?.1 ?? (buckets.count == 1 ? buckets.first?.1 : nil)
        let credits = defaultBucket?.credits.map { $0.unlimited ? "무제한" : $0.balance }.flatMap { $0 }
        return CodexUsageSnapshot(
            identity: CodexIdentity(email: identity.email, planType: identity.planType ?? defaultBucket?.planType,
                                    accountID: response.accountId ?? response.account_id ?? identity.accountID),
            windows: windows, credits: credits,
            ordinaryUsageAllowed: response.ordinaryUsageAllowed
        )
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CodexClientError.malformedProtocol }
    }

    private struct AccountResponse: Decodable {
        let account: Account?
        let accountId: String?
        let account_id: String?
    }
    private struct Account: Decodable {
        let type: String
        let email: String?
        let planType: String?
        let accountId: String?
        let account_id: String?
    }
    private struct UsageResponse: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let accountId: String?
        let account_id: String?
        let ordinaryUsageAllowed: Bool?

        private enum CodingKeys: String, CodingKey {
            case rateLimits, rateLimitsByLimitId, accountId, account_id, ordinaryUsageAllowed
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            rateLimitsByLimitId = try values.decodeIfPresent([String: Bucket].self, forKey: .rateLimitsByLimitId)
            // The legacy mirror is irrelevant when the authoritative map exists, even if empty.
            rateLimits = rateLimitsByLimitId == nil ? try values.decodeIfPresent(Bucket.self, forKey: .rateLimits) : nil
            accountId = try values.decodeIfPresent(String.self, forKey: .accountId)
            account_id = try values.decodeIfPresent(String.self, forKey: .account_id)
            ordinaryUsageAllowed = try values.decodeIfPresent(Bool.self, forKey: .ordinaryUsageAllowed)
        }
    }
    private struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }
    private struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
    }
    private struct Credits: Decodable {
        let balance: String?
        let unlimited: Bool
    }
}
