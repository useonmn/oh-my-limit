import Foundation

public enum ClaudeClientError: Error, LocalizedError, Sendable {
    case unauthorized
    case rateLimited
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
    private let usageURL: URL

    public init() {
        usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    }

    init(usageURL: URL) {
        self.usageURL = usageURL
    }

    public func fetchUsage(accessToken: String, identity: CodexIdentity,
                           source: UsageSource = .claudeOAuth) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            throw ClaudeClientError.requestFailed
        }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw ClaudeClientError.unauthorized
        case 429: throw ClaudeClientError.rateLimited
        default: throw ClaudeClientError.requestFailed
        }
        guard data.count <= 1_048_576 else { throw ClaudeClientError.invalidResponse }
        return try ClaudeUsageParser.parse(data, identity: identity, source: source)
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
        guard windows.contains(where: \.usageKnown) else { throw ClaudeClientError.invalidResponse }
        return CodexUsageSnapshot(identity: identity, windows: windows, source: source)
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
