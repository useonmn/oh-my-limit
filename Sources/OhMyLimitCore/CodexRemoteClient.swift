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
        return try CodexRemoteParser.usage(from: data, credentials: credentials, now: Date())
    }

    private func send(_ input: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport(input)
            try Task.checkCancellation()
            guard data.count <= 65_536 else { throw CodexOAuthError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                // Only 401 means the token is bad; 403 is a policy/edge block that
                // token renewal cannot fix, so it must not rotate the refresh token.
                if response.statusCode == 401 { throw CodexOAuthError.signInRequired }
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
/// Field-level decoding is lenient (numbers may arrive as strings, unknown shapes are
/// dropped) so one odd field degrades a row instead of failing the whole account.
enum CodexRemoteParser {
    private struct Payload: Decodable {
        let planType: String?
        let rateLimit: Meter?
        let credits: Credits?
        /// Raw entries keep their index so extra window IDs stay stable when one is malformed.
        let additional: [Additional?]
        let spendControl: SpendControl?

        private enum CodingKeys: String, CodingKey {
            case plan_type, rate_limit, credits, additional_rate_limits, spend_control
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            planType = fields.lenient(String.self, forKey: .plan_type)
            rateLimit = fields.lenient(Meter.self, forKey: .rate_limit)
            credits = fields.lenient(Credits.self, forKey: .credits)
            additional = fields.lenient([Lossy<Additional>].self, forKey: .additional_rate_limits)?.map(\.value) ?? []
            spendControl = fields.lenient(SpendControl.self, forKey: .spend_control)
        }

        struct Meter: Decodable {
            let allowed: Bool?
            let limitReached: Bool?
            let primary: Window?
            let secondary: Window?

            private enum CodingKeys: String, CodingKey {
                case allowed, limit_reached, primary_window, secondary_window
            }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                allowed = fields.lenient(Bool.self, forKey: .allowed)
                limitReached = fields.lenient(Bool.self, forKey: .limit_reached)
                primary = fields.lenient(Window.self, forKey: .primary_window)
                secondary = fields.lenient(Window.self, forKey: .secondary_window)
            }
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAfterSeconds: Double?
            let resetAt: Double?

            private enum CodingKeys: String, CodingKey {
                case used_percent, limit_window_seconds, reset_after_seconds, reset_at
            }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                // Malformed usage remains an unknown window, not a missing row.
                usedPercent = fields.number(forKey: .used_percent)
                limitWindowSeconds = fields.number(forKey: .limit_window_seconds)
                resetAfterSeconds = fields.number(forKey: .reset_after_seconds)
                resetAt = fields.number(forKey: .reset_at)
            }

            var isEmpty: Bool {
                usedPercent == nil && limitWindowSeconds == nil && resetAfterSeconds == nil && resetAt == nil
            }
        }

        struct Credits: Decodable {
            let hasCredits: Bool?
            let unlimited: Bool?
            let balance: String?

            private enum CodingKeys: String, CodingKey { case has_credits, unlimited, balance }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                hasCredits = fields.lenient(Bool.self, forKey: .has_credits)
                unlimited = fields.lenient(Bool.self, forKey: .unlimited)
                // Adapted from oh-my-pi (MIT) usage/openai-codex.ts: balance is `string | number`.
                balance = fields.lenient(String.self, forKey: .balance)
                    ?? fields.lenient(Double.self, forKey: .balance).flatMap { $0.isFinite ? CodexRemoteParser.numberText($0) : nil }
            }
        }

        struct Additional: Decodable {
            let limitName: String?
            let meteredFeature: String?
            let rateLimit: Meter?

            private enum CodingKeys: String, CodingKey { case limit_name, metered_feature, rate_limit }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                limitName = fields.lenient(String.self, forKey: .limit_name)
                meteredFeature = fields.lenient(String.self, forKey: .metered_feature)
                rateLimit = fields.lenient(Meter.self, forKey: .rate_limit)
            }
        }

        /// Credit-billed workspace seats report a per-user spend cap instead of `rate_limit`.
        struct SpendControl: Decodable {
            let reached: Bool?
            let used: Double?
            let limit: Double?
            let remaining: Double?
            let usedPercent: Double?
            let resetAfterSeconds: Double?
            let resetAt: Double?
            let hasIndividualLimit: Bool

            private enum CodingKeys: String, CodingKey { case reached, individual_limit }
            private enum LimitKeys: String, CodingKey {
                case used, limit, remaining, used_percent, reset_after_seconds, reset_at
            }

            init(from decoder: any Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                reached = fields.lenient(Bool.self, forKey: .reached)
                let individual = try? fields.nestedContainer(keyedBy: LimitKeys.self, forKey: .individual_limit)
                hasIndividualLimit = individual != nil
                used = individual?.number(forKey: .used)
                limit = individual?.number(forKey: .limit)
                remaining = individual?.number(forKey: .remaining)
                usedPercent = individual?.number(forKey: .used_percent)
                resetAfterSeconds = individual?.number(forKey: .reset_after_seconds)
                resetAt = individual?.number(forKey: .reset_at)
            }
        }
    }

    /// Decodes one array element without letting a malformed sibling discard the rest.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    static func usage(from data: Data, credentials: CodexOAuthCredentials,
                      now: Date = Date()) throws -> CodexUsageSnapshot {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CodexOAuthError.invalidResponse
        }
        var windows: [CodexQuotaWindow] = []
        appendWindows(from: payload.rateLimit, key: "codex", limitName: nil, now: now, into: &windows)
        for (index, extra) in payload.additional.enumerated() {
            guard let extra else { continue }
            appendWindows(from: extra.rateLimit, key: "extra.\(index).\(extra.meteredFeature ?? "unnamed")",
                          limitName: extra.limitName ?? extra.meteredFeature ?? "추가 한도", now: now, into: &windows)
        }
        if let spendCap = payload.spendControl.flatMap({ spendCapWindow($0, now: now) }) {
            windows.append(spendCap)
        }
        guard !windows.isEmpty else { throw CodexOAuthError.invalidResponse }
        let credits = payload.credits.flatMap { credits -> String? in
            guard credits.hasCredits == true else { return nil }
            return credits.unlimited == true ? "무제한" : credits.balance
        }
        // Adapted from oh-my-pi (MIT) usage/openai-codex.ts: `limit_reached` is a denial
        // even when `allowed` is absent; seats without plan windows use the spend-cap verdict.
        let ordinaryUsageAllowed: Bool?
        if let meter = payload.rateLimit {
            ordinaryUsageAllowed = meter.limitReached == true ? false : meter.allowed
        } else {
            ordinaryUsageAllowed = payload.spendControl?.reached.map { !$0 }
        }
        return CodexUsageSnapshot(
            identity: CodexIdentity(
                email: credentials.email,
                planType: payload.planType ?? credentials.planType,
                accountID: credentials.accountID
            ),
            windows: windows,
            credits: credits,
            fetchedAt: now,
            ordinaryUsageAllowed: ordinaryUsageAllowed,
            source: .codexOAuth
        )
    }

    private static func appendWindows(from meter: Payload.Meter?, key: String, limitName: String?,
                                      now: Date, into windows: inout [CodexQuotaWindow]) {
        guard let meter else { return }
        for (slot, window) in [("primary", meter.primary), ("secondary", meter.secondary)] {
            // A window object with no recognised field carries nothing to show.
            guard let window, !window.isEmpty else { continue }
            let used = window.usedPercent.flatMap { $0 >= 0 ? $0 : nil }
            let minutes = window.limitWindowSeconds.flatMap { seconds -> Int? in
                guard seconds > 0, seconds <= Double(Int32.max) else { return nil }
                return Int((seconds / 60).rounded(.up))
            }
            let label: String
            if let limitName {
                label = limitName
            } else if let minutes {
                // Adapted from oh-my-pi (MIT) usage/openai-codex.ts: label any window by its duration.
                label = CodexQuotaWindow.durationLabel(minutes: minutes)
            } else {
                label = slot == "primary" ? "기본 한도" : "보조 한도"
            }
            windows.append(CodexQuotaWindow(
                id: "\(key).\(slot)", label: label, usedPercent: used ?? 0,
                windowDurationMins: minutes,
                resetsAt: resetDate(at: window.resetAt, after: window.resetAfterSeconds, now: now),
                usageKnown: used != nil
            ))
        }
    }

    /// Adapted from oh-my-pi (MIT) usage/openai-codex.ts (`parseSpendCap`, `buildSpendCapLimit`).
    private static func spendCapWindow(_ cap: Payload.SpendControl, now: Date) -> CodexQuotaWindow? {
        guard cap.hasIndividualLimit else { return nil }
        // Absolute amounts keep sub-percent precision; `used_percent` is integer-rounded.
        let fraction: Double?
        if let used = cap.used, let limit = cap.limit, limit > 0 {
            fraction = used / limit
        } else if let percent = cap.usedPercent {
            fraction = percent / 100
        } else if let remaining = cap.remaining, remaining <= 0 {
            fraction = 1
        } else {
            fraction = nil
        }
        guard fraction != nil || cap.used != nil || cap.limit != nil || cap.remaining != nil else { return nil }
        // The backend verdict stands in when the counters cannot give a percentage.
        // A tiny limit can overflow the ratio; a non-finite percentage would trap in CodexQuotaWindow.
        let percent = fraction.flatMap { $0.isFinite ? max(0, $0) * 100 : nil } ?? (cap.reached == true ? 100 : nil)
        return CodexQuotaWindow(
            id: "codex.spend-cap", label: "크레딧 한도", usedPercent: percent ?? 0,
            windowDurationMins: nil,
            resetsAt: resetDate(at: cap.resetAt, after: cap.resetAfterSeconds, now: now),
            usageKnown: percent != nil
        )
    }

    /// Adapted from oh-my-pi (MIT) usage/openai-codex.ts (`resolveResetTime`):
    /// `reset_at` above 1e12 is milliseconds; `reset_after_seconds` is the fallback.
    private static func resetDate(at resetAt: Double?, after resetAfter: Double?, now: Date) -> Date? {
        // Far-out values overflow the Int minute countdowns in the UI and would be cached; drop them.
        let bound: TimeInterval = 1e11
        if let resetAt {
            let seconds = resetAt > 1_000_000_000_000 ? resetAt / 1000 : resetAt
            return abs(seconds) <= bound ? Date(timeIntervalSince1970: seconds) : nil
        }
        return resetAfter.flatMap { abs($0) <= bound ? now.addingTimeInterval($0) : nil }
    }

    private static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

private extension KeyedDecodingContainer {
    /// A present value of the wrong type reads as absent instead of failing the payload.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// A finite JSON number or numeric string (the backend sends both).
    func number(forKey key: Key) -> Double? {
        let value = lenient(Double.self, forKey: key)
            ?? lenient(String.self, forKey: key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
}
