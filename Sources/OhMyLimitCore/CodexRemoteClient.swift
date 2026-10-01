import Foundation

/// Fetches Codex usage for a directly logged-in ChatGPT account from the
/// ChatGPT backend usage API — no codex binary involved.
public struct CodexRemoteClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let usageURL: String
    private let transport: Transport

    public init(usageURL: String = CodexOAuthConfiguration.usageURL) {
        self.init(usageURL: usageURL, transport: CodexOAuthHTTPS.send)
    }

    init(usageURL: String, transport: @escaping Transport) {
        self.usageURL = usageURL
        self.transport = transport
    }

    public func fetchUsage(_ credentials: CodexOAuthCredentials) async throws -> CodexUsageSnapshot {
        guard let url = URL(string: usageURL) else { throw CodexOAuthError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue(CodexOAuthConfiguration.originator, forHTTPHeaderField: "originator")
        request.setValue(CodexOAuthConfiguration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        return try CodexRemoteParser.usage(from: data, credentials: credentials)
    }

    private func send(_ input: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport(input)
            try Task.checkCancellation()
            guard data.count <= 65_536 else { throw CodexOAuthError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw CodexOAuthError.signInRequired
                }
                throw CodexOAuthError.authorizationFailed(response.statusCode)
            }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? CodexOAuthError { throw error }
            if (error as? URLError)?.code == .timedOut { throw CodexOAuthError.timedOut }
            throw CodexOAuthError.networkFailure
        }
    }
}

/// Maps the `wham/usage` payload to the snapshot shape the app already renders.
/// The wire format uses snake_case windows; the RPC shape uses camelCase.
enum CodexRemoteParser {
    private struct Payload: Decodable {
        let plan_type: String?
        let account_id: String?
        let rate_limit: Details?
        let credits: Credits?
        let additional_rate_limits: [Additional]?

        struct Details: Decodable {
            let allowed: Bool?
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_at: Int?
        }
        struct Credits: Decodable {
            let has_credits: Bool?
            let unlimited: Bool?
            let balance: String?
        }
        struct Additional: Decodable {
            let limit_name: String?
            let metered_feature: String?
            let rate_limit: Details?
        }
    }

    static func usage(from data: Data, credentials: CodexOAuthCredentials) throws -> CodexUsageSnapshot {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CodexOAuthError.invalidResponse
        }
        var windows: [CodexQuotaWindow] = []
        appendWindows(from: payload.rate_limit, key: "codex", limitName: nil, into: &windows)
        for extra in payload.additional_rate_limits ?? [] {
            appendWindows(from: extra.rate_limit, key: extra.metered_feature ?? "extra",
                          limitName: extra.limit_name, into: &windows)
        }
        guard !windows.isEmpty else { throw CodexOAuthError.invalidResponse }
        let credits = payload.credits.flatMap { credits -> String? in
            guard credits.has_credits == true else { return nil }
            return credits.unlimited == true ? "무제한" : credits.balance
        }
        return CodexUsageSnapshot(
            identity: CodexIdentity(
                email: credentials.email,
                planType: payload.plan_type ?? credentials.planType,
                accountID: payload.account_id ?? credentials.accountID
            ),
            windows: windows,
            credits: credits,
            ordinaryUsageAllowed: payload.rate_limit?.allowed,
            source: .codexOAuth
        )
    }

    private static func appendWindows(from details: Payload.Details?, key: String,
                                      limitName: String?, into windows: inout [CodexQuotaWindow]) {
        guard let details else { return }
        for (slot, window) in [("primary", details.primary_window), ("secondary", details.secondary_window)] {
            guard let window, let used = window.used_percent,
                  used.isFinite, used >= 0 else { continue }
            let minutes = window.limit_window_seconds.flatMap { $0 > 0 ? ($0 + 59) / 60 : nil }
            let label: String
            if key == "codex" {
                switch minutes {
                case 300: label = "5시간"
                case 10_080: label = "주간"
                default: label = limitName ?? key
                }
            } else {
                label = limitName ?? key
            }
            windows.append(CodexQuotaWindow(
                id: "\(key).\(slot)", label: label, usedPercent: used,
                windowDurationMins: minutes,
                resetsAt: window.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }
    }
}
