import Foundation

public enum ClaudeClientError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    /// `retryAfter` is the server's Retry-After in seconds, clamped to 0...3600; nil when absent or unparseable.
    case rateLimited(retryAfter: TimeInterval?)
    case requestFailed
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Claude 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .rateLimited: "Claude 사용량 조회가 제한되었습니다. 잠시 후 다시 시도해 주세요."
        case .requestFailed: "Claude 사용량을 가져오지 못했습니다. 네트워크를 확인해 주세요."
        case .invalidResponse: "Claude 사용량 응답을 읽을 수 없습니다."
        }
    }
}

/// Reads Claude subscription usage with an access token from this app's own Claude login.
public struct ClaudeClient: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    // Adapted from oh-my-pi (MIT) usage/claude.ts: bounded in-fetch retry for transient failures.
    static let maxAttempts = 3
    static let baseRetryDelay: TimeInterval = 0.5
    /// A server-requested wait longer than this ends the fetch; UsageMonitor's backoff takes over.
    static let maxRetryDelay: TimeInterval = 5

    private let usageURL: URL
    private let sleep: Sleep

    public init() {
        self.init(usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    }

    init(usageURL: URL, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.usageURL = usageURL
        self.sleep = sleep
    }

    /// Retries 408/5xx (except 501), dropped connections, garbled JSON, and usage-shaped bodies without
    /// numbers. Never retries 401/403/429: those are the server's answer for this poll.
    public func fetchUsage(accessToken: String, identity: CodexIdentity) async throws -> CodexUsageSnapshot {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let failure: TransientFailure
            do { return try await fetchOnce(accessToken: accessToken, identity: identity) }
            catch let transient as TransientFailure { failure = transient }
            guard attempt + 1 < Self.maxAttempts,
                  let delay = Self.retryDelay(attempt: attempt, retryAfter: failure.retryAfter) else {
                throw failure.error
            }
            do { try await sleep(.milliseconds(Int((delay * 1000).rounded()))) }
            catch { throw CancellationError() }
            attempt += 1
        }
    }

    private struct TransientFailure: Error {
        let error: ClaudeClientError
        let retryAfter: TimeInterval?
    }

    private func fetchOnce(accessToken: String, identity: CodexIdentity) async throws -> CodexUsageSnapshot {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("OhMyLimit", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await OAuthHTTPS.send(
                request, limit: 1_048_576, invalidResponse: ClaudeClientError.invalidResponse, resourceTimeout: 15
            )
        }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? ClaudeClientError { throw error }
            if Self.isTransient(error) { throw TransientFailure(error: .requestFailed, retryAfter: nil) }
            throw ClaudeClientError.requestFailed
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ClaudeClientError.unauthorized
        case 429:
            throw ClaudeClientError.rateLimited(
                retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
            )
        case 408, 500, 502...599:
            throw TransientFailure(
                error: .requestFailed,
                retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
            )
        default: throw ClaudeClientError.requestFailed
        }
        // An empty or non-JSON 2xx (captive portal, proxy page) is not Anthropic answering; retrying won't help.
        let whitespace: [UInt8] = [0x20, 0x09, 0x0A, 0x0D]
        guard data.contains(where: { !whitespace.contains($0) }) else { throw ClaudeClientError.requestFailed }
        do { return try ClaudeUsageParser.parse(data, identity: identity, source: .claudeOAuth) }
        catch {
            let claimsJSON = response.value(forHTTPHeaderField: "Content-Type")?
                .range(of: "json", options: .caseInsensitive) != nil
            if !claimsJSON, (try? JSONSerialization.jsonObject(with: data)) == nil {
                throw ClaudeClientError.requestFailed
            }
            throw TransientFailure(error: .invalidResponse, retryAfter: nil)
        }
    }

    /// `max(0.5s·2^attempt, Retry-After)`, or nil when that exceeds `maxRetryDelay`.
    static func retryDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        let delay = max(baseRetryDelay * pow(2, Double(attempt)), retryAfter ?? 0)
        return delay <= maxRetryDelay ? delay : nil
    }

    /// Connection-level failures that a prompt replay can fix. Timeouts are excluded to keep one fetch short.
    static func isTransient(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        let transient: [URLError.Code] = [
            .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse,
        ]
        return transient.contains(code)
    }

    /// Parses Retry-After as delta-seconds or an HTTP-date relative to `now`, clamped to 0...3600.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let seconds: TimeInterval
        if text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) {
            seconds = TimeInterval(text) ?? 3600
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: text) else { return nil }
            seconds = date.timeIntervalSince(now)
        }
        guard seconds.isFinite else { return nil }
        return min(max(seconds, 0), 3600)
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data, plan: String? = nil) throws -> CodexUsageSnapshot {
        try parse(data, identity: CodexIdentity(planType: plan), source: .claudeOAuth)
    }

    static func parse(_ data: Data, identity: CodexIdentity, source: UsageSource) throws -> CodexUsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeClientError.invalidResponse
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var windows: [CodexQuotaWindow] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String else { continue }
                let label: String
                let duration: Int
                let id: String
                switch kind {
                case "session": id = "claude.session"; label = "5시간"; duration = 300
                case "weekly_all": id = "claude.weekly"; label = "주간"; duration = 10_080
                case "weekly_scoped":
                    let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    let name = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !name.isEmpty else { continue }
                    id = "claude.model.\(name)"; label = "주간 · \(name)"; duration = 10_080
                default: continue
                }
                windows.append(window(id: id, label: label, duration: duration,
                                      percent: limit["percent"], reset: limit["resets_at"], fractional: fractional, plain: plain))
            }
        }
        if let session = root["five_hour"] as? [String: Any],
           !windows.contains(where: { $0.id == "claude.session" && $0.usageKnown }) {
            let fallback = window(id: "claude.session", label: "5시간", duration: 300,
                                  percent: session["utilization"], reset: session["resets_at"], fractional: fractional, plain: plain)
            if let index = windows.firstIndex(where: { $0.id == fallback.id }) { windows[index] = fallback }
            else { windows.insert(fallback, at: 0) }
        }
        if let weekly = root["seven_day"] as? [String: Any],
           !windows.contains(where: { $0.id == "claude.weekly" && $0.usageKnown }) {
            let fallback = window(id: "claude.weekly", label: "주간", duration: 10_080,
                                  percent: weekly["utilization"], reset: weekly["resets_at"], fractional: fractional, plain: plain)
            if let index = windows.firstIndex(where: { $0.id == fallback.id }) { windows[index] = fallback }
            else { windows.append(fallback) }
        }
        let credits = extraUsage(root)
        guard windows.contains(where: \.usageKnown) || credits != nil else { throw ClaudeClientError.invalidResponse }
        return CodexUsageSnapshot(identity: identity, windows: windows, credits: credits, source: source)
    }

    // Adapted from oh-my-pi (MIT) usage/claude.ts buildClaudeExtraUsageLimit.
    /// Pay-as-you-go extra usage as "$used / $limit", or "$used" when uncapped. `spend` supersedes the
    /// legacy `extra_usage` object whenever it is present and non-null. Only enabled USD balances count.
    static func extraUsage(_ root: [String: Any]) -> String? {
        let amount: (used: Double, limit: Double?)?
        if let spend = root["spend"], !(spend is NSNull) {
            amount = spendExtraUsage(spend)
        } else {
            amount = legacyExtraUsage(root["extra_usage"])
        }
        guard let amount else { return nil }
        let used = String(format: "$%.2f", amount.used)
        return amount.limit.map { "\(used) / \(String(format: "$%.2f", $0))" } ?? used
    }

    private static func spendExtraUsage(_ value: Any) -> (used: Double, limit: Double?)? {
        guard let spend = value as? [String: Any], isTrue(spend["enabled"]), spend.keys.contains("limit"),
              let usedMoney = spend["used"] as? [String: Any],
              let used = dollars(minor: usedMoney["amount_minor"], exponent: usedMoney["exponent"],
                                 currency: usedMoney["currency"], currencyRequired: true) else { return nil }
        if spend["limit"] is NSNull { return (used, nil) }
        guard let limitMoney = spend["limit"] as? [String: Any],
              let limit = dollars(minor: limitMoney["amount_minor"], exponent: limitMoney["exponent"],
                                  currency: limitMoney["currency"], currencyRequired: true),
              limit > 0 else { return nil }
        return (used, limit)
    }

    private static func legacyExtraUsage(_ value: Any?) -> (used: Double, limit: Double?)? {
        guard let usage = value as? [String: Any], isTrue(usage["is_enabled"]), usage.keys.contains("monthly_limit")
        else { return nil }
        let places: Any = usage["decimal_places"] ?? 2
        guard let used = dollars(minor: usage["used_credits"], exponent: places, currency: usage["currency"],
                                 currencyRequired: false) else { return nil }
        guard let limitValue = usage["monthly_limit"], !(limitValue is NSNull) else { return (used, nil) }
        guard let limit = dollars(minor: limitValue, exponent: places, currency: usage["currency"], currencyRequired: false),
              limit > 0 else { return nil }
        return (used, limit)
    }

    /// Minor units scaled by `10^exponent`; both must be nonnegative integers and the currency USD.
    private static func dollars(minor: Any?, exponent: Any?, currency: Any?, currencyRequired: Bool) -> Double? {
        guard let minor = integer(minor), let exponent = integer(exponent) else { return nil }
        if let currency {
            guard (currency as? String)?.uppercased() == "USD" else { return nil }
        } else if currencyRequired {
            return nil
        }
        let divisor = pow(10, Double(exponent))
        guard divisor.isFinite else { return nil }
        let value = Double(minor) / divisor
        return value.isFinite ? value : nil
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// A JSON safe integer >= 0; booleans are rejected even though they bridge to NSNumber.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= 9_007_199_254_740_991, double == double.rounded() else { return nil }
        return Int(double)
    }

    private static func window(id: String, label: String, duration: Int, percent: Any?, reset: Any?,
                               fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> CodexQuotaWindow {
        let value = (percent as? NSNumber)?.doubleValue
        let valid = value.map { $0.isFinite && $0 >= 0 } ?? false
        let date: Date? = (reset as? String).flatMap { text in
            fractional.date(from: text) ?? plain.date(from: text)
        }
        return CodexQuotaWindow(id: id, label: label, usedPercent: valid ? value! : 0,
                                windowDurationMins: duration, resetsAt: date, usageKnown: valid)
    }
}
