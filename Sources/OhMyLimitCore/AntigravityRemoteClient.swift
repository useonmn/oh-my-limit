import Foundation
import CoreFoundation

/// Read-only Cloud Code quota requests using exactly the supplied account's access token.
/// Token renewal and persistence belong to the caller, not this client.
public struct AntigravityRemoteClient: Sendable {
    private let loopbackPorts: [Int]
    private let timeout: TimeInterval
    private let version: AntigravityClientVersion

    public init() {
        loopbackPorts = []
        timeout = 10
        version = .shared
    }

    /// Internal test seam: only literal loopback addresses, never an arbitrary remote origin.
    /// `fallbackLoopbackPort` stands in for the sandbox quota host.
    init(loopbackPort: Int, fallbackLoopbackPort: Int? = nil, timeout: TimeInterval = 10,
         version: AntigravityClientVersion = AntigravityClientVersion(manifestURL: nil)) {
        loopbackPorts = [loopbackPort] + (fallbackLoopbackPort.map { [$0] } ?? [])
        self.timeout = timeout
        self.version = version
    }

    public func fetchUsage(credentials: AntigravityOAuthCredentials) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        guard !credentials.accessToken.isEmpty, credentials.accessToken.utf8.count <= 16_384,
              credentials.accessToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AntigravityOAuthError.signInRequired
        }
        guard loopbackPorts.allSatisfy({ (1...65535).contains($0) }) else { throw AntigravityOAuthError.invalidResponse }
        let userAgent = AntigravityClientVersion.userAgent(await version.current())
        try Task.checkCancellation()
        let peer = AntigravityRemoteSession(timeout: timeout, userAgent: userAgent)
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
        // Antigravity accounting uses the dedicated host, as in OpenCodex 2.55.0.
        let origins: [String]
        if !loopbackPorts.isEmpty {
            origins = (method == "loadCodeAssist" ? [loopbackPorts[0]] : loopbackPorts).map { "http://127.0.0.1:\($0)" }
        } else if method == "loadCodeAssist" {
            origins = ["https://cloudcode-pa.googleapis.com"]
        } else {
            origins = ["https://daily-cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.sandbox.googleapis.com"]
        }
        // Adapted from oh-my-pi (MIT) usage/google-antigravity.ts: a transient failure on one quota
        // host falls through to the next. Auth, permission and unsupported answers are final.
        for origin in origins.dropLast() {
            do {
                return try await send(peer, url: URL(string: "\(origin)/v1internal:\(method)")!, token: token, body: body)
            } catch {
                guard Self.isTransient(error), !Task.isCancelled, !peer.rejectedAuthentication else { throw error }
            }
        }
        return try await send(peer, url: URL(string: "\(origins.last!)/v1internal:\(method)")!, token: token, body: body)
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? AntigravityOAuthError { return error == .timedOut || error == .networkFailure }
        guard let error = error as? URLError else { return false }
        return ![.cancelled, .userAuthenticationRequired, .userCancelledAuthentication].contains(error.code)
    }

    private func send(_ peer: AntigravityRemoteSession, url: URL, token: String,
                      body: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(peer.userAgent, forHTTPHeaderField: "User-Agent")
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
                remaining: model["disabled"] as? Bool == true ? nil : fraction(quota) ?? blockedUntilReset(quota),
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

    /// Adapted from oh-my-pi (MIT) usage/google-antigravity.ts: model-level quota omits
    /// `remainingFraction` for an exhausted counter and keeps only `resetTime`. A present but
    /// malformed fraction stays unknown.
    private static func blockedUntilReset(_ quota: [String: Any]) -> Double? {
        guard quota["disabled"] as? Bool != true, quota["remainingFraction"] == nil,
              date(quota["resetTime"]) != nil else { return nil }
        return 0
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
    let userAgent: String
    private let lock = NSLock()
    private var authenticationRejected = false
    var rejectedAuthentication: Bool { lock.withLock { authenticationRejected } }
    init(timeout: TimeInterval, userAgent: String) {
        self.timeout = timeout
        self.userAgent = userAgent
    }

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
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
            // A proxy's own challenge is a network problem, not an expired Google sign-in.
            if !challenge.protectionSpace.isProxy() { lock.withLock { authenticationRejected = true } }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Antigravity client version for the `User-Agent`. The backend gates on the version, so it tracks
/// the official update manifest, looked up at most once per run (retried after a failure only once
/// `retryInterval` has passed), held in memory only, with a pinned fallback.
/// Adapted from oh-my-pi (MIT) wire/gemini-headers.ts.
actor AntigravityClientVersion {
    static let shared = AntigravityClientVersion(manifestURL: URL(
        string: "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml"))
    static let fallbackVersion = "2.26.0"
    private static let retryInterval: TimeInterval = 600
    private static let maximumManifestBytes = 65_536

    private let manifestURL: URL?
    private let timeout: TimeInterval
    private var discovered: String?
    private var lookup: Task<Void, Never>?
    private var failedAt: Date?
    private var waiters: [UUID: CheckedContinuation<String, Never>] = [:]

    /// A nil manifest URL never touches the network and always reports the fallback.
    init(manifestURL: URL?, timeout: TimeInterval = 3) {
        self.manifestURL = manifestURL
        self.timeout = timeout
    }

    /// Waits for the shared lookup. A cancelled caller stops waiting at once and gets the best
    /// known version; the lookup itself keeps running for the other callers.
    func current() async -> String {
        if let discovered { return discovered }
        guard let manifestURL else { return Self.fallbackVersion }
        if lookup == nil {
            if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryInterval { return Self.fallbackVersion }
            let timeout = self.timeout
            lookup = Task { await self.complete(Self.fetchVersion(manifestURL, timeout: timeout)) }
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: discovered ?? Self.fallbackVersion) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    private func complete(_ version: String?) {
        lookup = nil
        if let version { discovered = version } else { failedAt = Date() }
        let result = discovered ?? Self.fallbackVersion
        let pending = waiters.values
        waiters = [:]
        for continuation in pending { continuation.resume(returning: result) }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: discovered ?? Self.fallbackVersion)
    }

    /// Captured from the real `antigravity/hub` client. The macOS build is arm64 only and the
    /// backend does not validate `cl`; only the version gates.
    static func userAgent(_ version: String) -> String {
        "antigravity/hub/\(version) (aidev_client; os_type=darwin; arch=arm64; cl=1005016104)"
    }

    /// The first `version:` line of an electron-builder manifest, if it is a plain `x.y.z`.
    static func manifestVersion(_ yaml: String) -> String? {
        for line in yaml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = line.drop { $0 == " " || $0 == "\t" }
            guard rest.hasPrefix("version") else { continue }
            rest = rest.dropFirst("version".count).drop { $0 == " " || $0 == "\t" }
            guard rest.first == ":" else { continue }
            let body = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            let value: Substring
            let tail: Substring
            if let quote = body.first, quote == "\"" || quote == "'" {
                let inner = body.dropFirst()
                guard let end = inner.firstIndex(of: quote) else { continue }
                value = inner[..<end]
                tail = inner[inner.index(after: end)...]
            } else {
                value = body.prefix { !$0.isWhitespace && $0 != "#" }
                tail = body.dropFirst(value.count)
            }
            let trailing = tail.drop { $0 == " " || $0 == "\t" }
            guard !value.isEmpty, trailing.isEmpty || trailing.first == "#" else { continue }
            let version = value.trimmingCharacters(in: .whitespaces)
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            let valid = parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
            return valid ? version : nil
        }
        return nil
    }

    private static func fetchVersion(_ url: URL, timeout: TimeInterval) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("electron-builder", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  response.expectedContentLength <= maximumManifestBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumManifestBytes else { return nil }
                data.append(byte)
            }
            return manifestVersion(String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }
}
