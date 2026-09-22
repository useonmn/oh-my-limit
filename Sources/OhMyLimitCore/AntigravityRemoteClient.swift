import Foundation
import CoreFoundation

/// Read-only Cloud Code quota requests using exactly the supplied account's access token.
/// Token renewal and persistence belong to the caller, not this client.
public struct AntigravityRemoteClient: Sendable {
    private let loopbackPort: Int?
    private let timeout: TimeInterval

    public init() {
        loopbackPort = nil
        timeout = 10
    }

    /// Internal test seam: only a literal loopback address, never an arbitrary remote origin.
    init(loopbackPort: Int, timeout: TimeInterval = 10) {
        self.loopbackPort = loopbackPort
        self.timeout = timeout
    }

    public func fetchUsage(credentials: AntigravityOAuthCredentials) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        guard !credentials.accessToken.isEmpty, credentials.accessToken.utf8.count <= 16_384,
              credentials.accessToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AntigravityOAuthError.signInRequired
        }
        if let loopbackPort, !(1...65535).contains(loopbackPort) { throw AntigravityOAuthError.invalidResponse }
        let peer = AntigravityRemoteSession(timeout: timeout)
        defer { peer.session.invalidateAndCancel() }
        do {
            let assist: [String: Any]
            do {
                assist = try Self.object(await request(peer, "loadCodeAssist", token: credentials.accessToken,
                    body: ["metadata": ["ideType": "ANTIGRAVITY"]]))
            } catch AntigravityRemoteEndpointError.unsupported {
                // Optional metadata is unavailable; quota endpoints also accept an empty project body.
                assist = [:]
            } catch AntigravityOAuthError.quotaUnavailable {
                assist = [:]
            }
            let projectObject = assist["cloudaicompanionProject"] as? [String: Any]
            let project = Self.text(assist["cloudaicompanionProject"])
                ?? Self.text(projectObject?["id"]) ?? Self.text(projectObject?["projectId"])
            let body: [String: Any] = project.map { ["project": $0] } ?? [:]
            let plan = Self.text((assist["planInfo"] as? [String: Any])?["planType"])
                ?? Self.tier(assist["paidTier"]) ?? Self.tier(assist["currentTier"])
            let identity = CodexIdentity(email: credentials.identity.email, planType: plan,
                                         accountID: credentials.identity.accountID)
            let summary: Data?
            do {
                summary = try await request(peer, "retrieveUserQuotaSummary", token: credentials.accessToken, body: body)
            } catch AntigravityRemoteEndpointError.unsupported {
                summary = nil
            }
            let windows: [CodexQuotaWindow]
            if let summary {
                let root = try Self.object(summary)
                let payload = root["response"] as? [String: Any] ?? root["summary"] as? [String: Any] ?? root
                if payload["groups"] != nil {
                    // Even empty/unknown groups are authoritative. Never overwrite with catalog data.
                    windows = try AntigravityParser.summary(summary, source: .antigravityOAuth).windows
                } else if payload["models"] != nil {
                    windows = try await modelWindows(Self.models(payload), peer: peer, token: credentials.accessToken, body: body)
                } else {
                    throw AntigravityOAuthError.invalidResponse
                }
            } else {
                let models: [RemoteMeasurement]
                do {
                    models = try Self.models(Self.object(await request(peer, "fetchAvailableModels", token: credentials.accessToken, body: body)))
                } catch AntigravityRemoteEndpointError.unsupported {
                    return try await dedicatedSnapshot(peer, token: credentials.accessToken, body: body, identity: identity)
                } catch AntigravityOAuthError.quotaUnavailable {
                    return try await dedicatedSnapshot(peer, token: credentials.accessToken, body: body, identity: identity)
                }
                windows = try await modelWindows(models, peer: peer, token: credentials.accessToken, body: body)
            }
            try Task.checkCancellation()
            return CodexUsageSnapshot(identity: identity, windows: windows, source: .antigravityOAuth)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if peer.rejectedAuthentication { throw AntigravityOAuthError.signInRequired }
            if let error = error as? AntigravityOAuthError { throw error }
            if error is AntigravityRemoteEndpointError { throw AntigravityOAuthError.quotaUnavailable }
            if error is AntigravityClientError { throw AntigravityOAuthError.invalidResponse }
            if let error = error as? URLError {
                if error.code == .timedOut { throw AntigravityOAuthError.timedOut }
                if [.userAuthenticationRequired, .userCancelledAuthentication].contains(error.code) {
                    // We decline HTTP authentication challenges instead of consulting other credentials.
                    throw AntigravityOAuthError.signInRequired
                }
            }
            throw AntigravityOAuthError.networkFailure
        }
    }

    private func dedicatedSnapshot(_ peer: AntigravityRemoteSession, token: String, body: [String: Any],
                                   identity: CodexIdentity) async throws -> CodexUsageSnapshot {
        let data = try await request(peer, "retrieveUserQuota", token: token, body: body)
        return CodexUsageSnapshot(identity: identity, windows: try Self.quota(Self.object(data), catalog: []).map(\.window),
                                  source: .antigravityOAuth)
    }

    private func modelWindows(_ models: [RemoteMeasurement], peer: AntigravityRemoteSession,
                              token: String, body: [String: Any]) async throws -> [CodexQuotaWindow] {
        let measured = models.compactMap(\.remaining)
        // Missing/disabled members do not make otherwise all-full availability trustworthy.
        guard !measured.isEmpty, measured.allSatisfy({ $0 >= 0.999 }) else { return models.map(\.window) }
        let data = try await request(peer, "retrieveUserQuota", token: token, body: body)
        return try Self.quota(Self.object(data), catalog: models).map(\.window)
    }

    private func request(_ peer: AntigravityRemoteSession, _ method: String, token: String,
                         body: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        // Antigravity accounting uses the dedicated host, as in OpenCodex 2.55.0.
        let origin = loopbackPort.map { "http://127.0.0.1:\($0)" }
            ?? (method == "loadCodeAssist"
                ? "https://cloudcode-pa.googleapis.com" : "https://daily-cloudcode-pa.googleapis.com")
        let url = URL(string: "\(origin)/v1internal:\(method)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "antigravity/ide/2.5.5 (os_type=macos; arch=arm64; aidev_client; auth_method=oauth)",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard request.httpBody!.count <= Self.maximumBytes else { throw AntigravityOAuthError.invalidResponse }
        let (bytes, response) = try await peer.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw AntigravityOAuthError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401: throw AntigravityOAuthError.signInRequired
        case 403: throw AntigravityOAuthError.quotaUnavailable
        case 404, 405, 501: throw AntigravityRemoteEndpointError.unsupported
        case 408, 504: throw AntigravityOAuthError.timedOut
        case 429, 500...599: throw AntigravityOAuthError.networkFailure
        case 300...399: throw AntigravityOAuthError.invalidResponse
        default: throw AntigravityOAuthError.quotaUnavailable
        }
        guard response.expectedContentLength <= Self.maximumBytes else { throw AntigravityOAuthError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumBytes else { throw AntigravityOAuthError.invalidResponse }
            data.append(byte)
        }
        return data
    }

    private static let maximumBytes = 1_048_576

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityOAuthError.invalidResponse
        }
        if let error = root["error"] as? [String: Any] {
            switch error["code"] as? Int {
            case 401: throw AntigravityOAuthError.signInRequired
            case 403: throw AntigravityOAuthError.quotaUnavailable
            case 429, 500, 503: throw AntigravityOAuthError.networkFailure
            default: throw AntigravityOAuthError.invalidResponse
            }
        }
        return root
    }

    private struct RemoteMeasurement {
        let id: String
        let label: String
        let remaining: Double?
        let reset: Date?
        let description: String?

        var window: CodexQuotaWindow {
            CodexQuotaWindow(id: id, label: label, usedPercent: remaining.map { (1 - $0) * 100 } ?? 0,
                windowDurationMins: nil, resetsAt: reset, usageKnown: remaining != nil, resetDescription: description)
        }
    }

    private static func models(_ root: [String: Any]) throws -> [RemoteMeasurement] {
        guard let models = root["models"] as? [String: Any] else { throw AntigravityOAuthError.invalidResponse }
        return models.keys.sorted().map { id in
            let model = models[id] as? [String: Any] ?? [:]
            let quota = model["quotaInfo"] as? [String: Any] ?? [:]
            return RemoteMeasurement(id: id, label: text(model["displayName"]) ?? text(model["label"]) ?? id,
                remaining: model["disabled"] as? Bool == true ? nil : fraction(quota),
                reset: date(quota["resetTime"]), description: text(quota["description"]))
        }
    }

    private static func quota(_ root: [String: Any], catalog: [RemoteMeasurement]) throws -> [RemoteMeasurement] {
        guard let buckets = root["buckets"] as? [Any] else { throw AntigravityOAuthError.invalidResponse }
        // Keep separate buckets separate: their durations are not documented by this schema.
        return buckets.enumerated().compactMap { index, raw in
            guard let bucket = raw as? [String: Any], let model = text(bucket["modelId"]) else { return nil }
            let context = catalog.first { $0.id == model }
            return RemoteMeasurement(id: "\(model):\(index)", label: context?.label ?? model,
                remaining: fraction(bucket), reset: date(bucket["resetTime"]) ?? context?.reset,
                description: text(bucket["description"]) ?? context?.description)
        }
    }

    private static func fraction(_ quota: [String: Any]) -> Double? {
        guard quota["disabled"] as? Bool != true, let value = quota["remainingFraction"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              (0...1).contains(value.doubleValue) else { return nil }
        return value.doubleValue
    }

    private static func tier(_ raw: Any?) -> String? {
        let tier = raw as? [String: Any]
        return text(tier?["name"]) ?? text(tier?["id"])
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

private enum AntigravityRemoteEndpointError: Error { case unsupported }

/// Default system TLS verification; no custom trust, shared state, or redirect following.
private final class AntigravityRemoteSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let timeout: TimeInterval
    private let lock = NSLock()
    private var authenticationRejected = false
    var rejectedAuthentication: Bool { lock.withLock { authenticationRejected } }
    init(timeout: TimeInterval) { self.timeout = timeout }

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // cancelAuthenticationChallenge can surface as URLError.cancelled. Record its actual
            // cause before completing; unlike rejectProtectionSpace, this cannot retry the request.
            lock.withLock { authenticationRejected = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
