import Foundation
import CoreFoundation

/// Wire-only parsing. Missing, disabled or invalid measurements are never inferred as zero usage.
/// The only inferences are omp's exhausted shapes: a reset with no fraction, or a zero remaining amount.
enum AntigravityParser {
    private static let buckets: [(String, String, Int)] = [
        ("gemini-5h", "Gemini", 300), ("gemini-weekly", "Gemini", 10_080),
        ("3p-5h", "Claude + GPT", 300), ("3p-weekly", "Claude + GPT", 10_080)
    ]
    private struct Measurement {
        let remaining: Double?
        let reset: Date?
        let description: String?
    }

    static func summary(_ data: Data, source: UsageSource) throws -> CodexUsageSnapshot {
        let root = try object(data)
        try checkCode(root)
        let payload = root["response"] as? [String: Any] ?? root["summary"] as? [String: Any] ?? root
        return try summaryPayload(payload, source: source)
    }

    static func cli(_ data: Data) throws -> CodexUsageSnapshot {
        let report = try object(data)
        guard report["status"] as? String == "SUCCESS",
              let command = report["command"] as? [String: Any], command["name"] as? String == "usage",
              let payload = command["data"] as? [String: Any] else { throw AntigravityClientError.malformedResponse }
        // Reports have no documented account identity. Every report gets a fresh empty identity.
        return try summaryPayload(payload, source: .antigravityCLI)
    }

    private static func summaryPayload(_ payload: [String: Any], source: UsageSource) throws -> CodexUsageSnapshot {
        guard let groups = payload["groups"] as? [Any] else { throw AntigravityClientError.malformedResponse }
        var values: [String: Measurement] = [:]
        var extras: [(id: String, label: String, duration: Int?)] = []
        for group in groups {
            let groupObject = group as? [String: Any]
            for raw in groupObject?["buckets"] as? [Any] ?? [] {
                guard let bucket = raw as? [String: Any],
                      let id = field(bucket, "bucketId", "bucket_id") as? String ?? bucket["id"] as? String,
                      values[id] == nil else { continue }
                let disabled = bucket["disabled"] as? Bool == true
                let isFixed = buckets.contains(where: { $0.0 == id })
                // Adapted from oh-my-pi (MIT) usage/google-antigravity.ts: buckets beyond the fixed
                // schema are real quota too; keep enabled ones (bounded) instead of dropping them.
                if !isFixed {
                    guard !disabled, extras.count < 16, let name = text(id) else { continue }
                    extras.append((id, extraLabel(name, group: text(groupObject?["displayName"])),
                        duration("\(text(bucket["window"]) ?? "") \(text(bucket["displayName"]) ?? "") \(name)")))
                }
                let remaining = bucket["remaining"] as? [String: Any] ?? [:]
                let oneof = remaining["case"] as? String == "remainingFraction" ? remaining["value"] : nil
                let fraction = field(bucket, "remainingFraction", "remaining_fraction")
                    ?? field(remaining, "remainingFraction", "remaining_fraction") ?? oneof
                values[id] = Measurement(
                    remaining: disabled ? nil : number(fraction) ?? exhaustedAmount(field(bucket, "remainingAmount", "remaining_amount")),
                    reset: date(field(bucket, "resetTime", "reset_time")),
                    description: text(bucket["description"]))
            }
        }
        let fixed = snapshot(values, identity: CodexIdentity(), source: source)
        return CodexUsageSnapshot(identity: fixed.identity, windows: fixed.windows + extras.map { id, label, duration in
            window(id: id, label: label, duration: duration, value: values[id])
        }, source: source)
    }

    /// Adapted from oh-my-pi (MIT) usage/google-antigravity.ts: a summary bucket without a fraction
    /// but with `remainingAmount` 0 is exhausted. Any other amount has no known limit to compare to.
    private static func exhaustedAmount(_ raw: Any?) -> Double? {
        let amount: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { amount = number.doubleValue }
        else if let string = raw as? String { amount = Double(string.trimmingCharacters(in: .whitespaces)) }
        else { amount = nil }
        return amount == 0 ? 0 : nil
    }

    /// Window length from a bucket's window, display name or id. Adapted from oh-my-pi (MIT)
    /// usage/google-antigravity.ts `classifyWindow`.
    private static func duration(_ source: String) -> Int? {
        let source = source.lowercased()
        if source.contains("week") || source.contains("7d") || source.range(of: #"7[\s_-]*day"#, options: .regularExpression) != nil {
            return 10_080
        }
        if source.contains("5h") || source.contains("five hour") || source.range(of: #"5[\s_-]*hour"#, options: .regularExpression) != nil {
            return 300
        }
        if source.contains("day") || source.contains("daily") || source.contains("24h") { return 1_440 }
        return nil
    }

    /// "gemini-argon-weekly" reads "Gemini (Argon)"; ids outside the known families use the group name.
    private static func extraLabel(_ id: String, group: String?) -> String {
        let lower = id.lowercased()
        let family: String
        let qualifier: Substring
        if lower.hasPrefix("gemini-") { family = "Gemini"; qualifier = id.dropFirst("gemini-".count) }
        else if lower.hasPrefix("3p-") { family = "Claude + GPT"; qualifier = id.dropFirst("3p-".count) }
        else { return group ?? id }
        let windowTokens: Set<String> = ["5h", "weekly", "week", "7d", "daily", "day", "24h"]
        let words = qualifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .filter { !windowTokens.contains($0.lowercased()) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? family : "\(family) (\(words.joined(separator: " ")))"
    }

    static func legacy(_ data: Data, source: UsageSource) throws -> CodexUsageSnapshot {
        let root = try object(data)
        try checkCode(root)
        guard let status = root["userStatus"] as? [String: Any] else { throw AntigravityClientError.malformedResponse }
        let tier = status["userTier"] as? [String: Any]
        let plan = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let identity = CodexIdentity(email: text(status["email"]), planType: text(tier?["name"]) ?? text(plan?["planName"]))
        let configs = (status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? []
        var values: [String: Measurement] = [:]
        let blacklist: Set<String> = ["MODEL_CHAT_20706", "MODEL_CHAT_23310", "MODEL_GOOGLE_GEMINI_2_5_FLASH",
            "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING", "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE",
            "MODEL_GOOGLE_GEMINI_2_5_PRO", "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"]
        var unknownPools = Set<String>()
        for config in configs {
            guard let label = text(config["label"]) else { continue }
            let model = (config["modelOrAlias"] as? [String: Any])?["model"] as? String
            if let model, blacklist.contains(model) { continue }
            let id = label.lowercased().contains("gemini") ? "gemini-5h" : "3p-5h"
            let quota = config["quotaInfo"] as? [String: Any] ?? [:]
            // Adapted from oh-my-pi (MIT) usage/google-antigravity.ts: an exhausted counter omits
            // `remainingFraction` and keeps only `resetTime`; a malformed fraction stays unknown.
            let blocked: Double? = quota["remainingFraction"] == nil && date(quota["resetTime"]) != nil ? 0 : nil
            guard let fraction = number(quota["remainingFraction"]) ?? blocked else {
                unknownPools.insert(id)
                continue
            }
            if values[id]?.remaining.map({ fraction >= $0 }) == true { continue }
            values[id] = Measurement(remaining: fraction, reset: date(quota["resetTime"]), description: nil)
        }
        // A pool with an unmeasured member cannot honestly claim a known worst-case percentage.
        for id in unknownPools { values[id] = nil }
        return snapshot(values, identity: identity, source: source)
    }

    private static func snapshot(_ values: [String: Measurement], identity: CodexIdentity, source: UsageSource) -> CodexUsageSnapshot {
        CodexUsageSnapshot(identity: identity, windows: buckets.map { id, label, duration in
            window(id: id, label: label, duration: duration, value: values[id])
        }, source: source)
    }

    private static func window(id: String, label: String, duration: Int?, value: Measurement?) -> CodexQuotaWindow {
        CodexQuotaWindow(id: id, label: label, usedPercent: value?.remaining.map { (1 - $0) * 100 } ?? 0,
            windowDurationMins: duration, resetsAt: value?.reset, usageKnown: value?.remaining != nil,
            resetDescription: value?.description)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityClientError.malformedResponse
        }
        return value
    }
    private static func checkCode(_ root: [String: Any]) throws {
        guard let code = root["code"] else { return }
        if let number = code as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number == 0 { return }
        if let string = code as? String, ["0", "ok", "success"].contains(string.lowercased()) { return }
        throw AntigravityClientError.localUnavailable
    }
    private static func field(_ object: [String: Any], _ camel: String, _ snake: String) -> Any? { object[camel] ?? object[snake] }
    private static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && (0...1).contains(value) ? value : nil
    }
    private static func text(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private static func date(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
