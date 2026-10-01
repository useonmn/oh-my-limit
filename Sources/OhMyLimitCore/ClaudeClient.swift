import Foundation
import LocalAuthentication
import Security

public enum ClaudeClientError: Error, LocalizedError, Sendable {
    case notLoggedIn
    case keychainUnavailable
    case expired
    /// The short-lived access token lapsed but Claude Code still holds a live refresh
    /// token; only Claude Code may rotate it, so this is a wait, not a logout.
    case awaitingClaudeCodeRefresh
    case unauthorized
    case rateLimited
    case requestFailed
    case cliMissing
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Claude Code에 먼저 로그인해 주세요."
        case .keychainUnavailable: "Claude Code 키체인을 읽을 수 없습니다. 키체인 접근을 허용해 주세요."
        case .expired, .unauthorized: "Claude Code 로그인이 만료되었습니다. Claude Code에서 다시 로그인해 주세요."
        case .awaitingClaudeCodeRefresh: "Claude Code 로그인은 유지 중입니다. Claude Code를 한 번 실행하면 토큰이 갱신되어 사용량이 다시 표시됩니다."
        case .rateLimited: "Claude 사용량 조회가 제한되었습니다. 잠시 후 다시 시도해 주세요."
        case .requestFailed: "Claude 사용량을 가져오지 못했습니다. 네트워크를 확인해 주세요."
        case .cliMissing: "Claude Code 실행 파일을 찾지 못했습니다. 먼저 Claude Code를 설치해 주세요."
        case .invalidResponse: "Claude 사용량 응답을 읽을 수 없습니다."
        }
    }
}

/// Reads Claude Code's existing login and launches only its official sign-in command.
public struct ClaudeClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: ClaudeNoRedirect(), delegateQueue: nil)
    }

    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        // A GUI launch must not run a relative PATH entry from an arbitrary directory.
        let candidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/claude" }
            + ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first(where: {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
    }

    /// Terminal runs this one-use script so Claude Code can handle browser callbacks
    /// and interactive verification itself. No token passes through this app.
    public static func prepareLoginCommand(in directory: URL, executableURL: URL,
                                           configDirectory: URL? = nil) throws -> URL {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeClientError.cliMissing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("claude-login-\(UUID().uuidString).command")
        let config = configDirectory.map { "export CLAUDE_CONFIG_DIR=\(shellQuoted($0.path))\n" } ?? ""
        let script = "#!/bin/sh\ntrap 'rm -f -- \"$0\"' EXIT\n\(config)\(shellQuoted(executableURL.path)) auth login --claudeai\n"
        do {
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func fetchUsage(home: URL, allowKeychainInteraction: Bool = false) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        let credentials = try Self.credentials(home: home, allowInteraction: allowKeychainInteraction)
        try credentials.checkUsable(now: Date())
        return try await fetchUsage(accessToken: credentials.accessToken,
                                    identity: CodexIdentity(planType: credentials.plan), source: .claudeCode)
    }

    public func fetchUsage(accessToken: String, identity: CodexIdentity,
                           source: UsageSource = .claudeOAuth) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OhMyLimit", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ClaudeClientError.requestFailed
        }
        guard let response = response as? HTTPURLResponse else { throw ClaudeClientError.requestFailed }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw ClaudeClientError.unauthorized
        case 429: throw ClaudeClientError.rateLimited
        default: throw ClaudeClientError.requestFailed
        }
        guard data.count <= 1_048_576 else { throw ClaudeClientError.invalidResponse }
        return try ClaudeUsageParser.parse(data, identity: identity, source: source)
    }

    struct Credentials {
        let accessToken: String
        let expiresAt: Double?
        let plan: String?
        /// Whether Claude Code can still renew the access token. The refresh token
        /// itself is never kept: this app must not use or rotate it.
        let refreshable: Bool

        func checkUsable(now: Date) throws {
            let nowMillis = now.timeIntervalSince1970 * 1_000
            guard let expiresAt, expiresAt <= nowMillis else { return }
            throw refreshable ? ClaudeClientError.awaitingClaudeCodeRefresh : ClaudeClientError.expired
        }
    }

    private static func credentials(home: URL, allowInteraction: Bool) throws -> Credentials {
        // Claude Code stores its macOS login in the user's login Keychain, with a
        // 0600 file fallback when the Keychain cannot accept writes.
        let config = home.standardizedFileURL.path
        let service = config == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
            ? "Claude Code-credentials" : "Claude Code-credentials-\(config)"
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        let (status, data) = OAuthSystemSecurity().copyMatching(query)
        var candidates: [Credentials] = []
        if status == errSecSuccess, let data,
           let credential = decodeCredentials(data) { candidates.append(credential) }
        let file = home.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let credential = decodeCredentials(data) {
            candidates.append(credential)
        }
        guard let selected = candidates.max(by: { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }) else {
            if status != errSecSuccess && status != errSecItemNotFound {
                throw ClaudeClientError.keychainUnavailable
            }
            throw ClaudeClientError.notLoggedIn
        }
        if status != errSecSuccess && status != errSecItemNotFound,
           selected.expiresAt.map({ $0 <= Date().timeIntervalSince1970 * 1_000 }) == true {
            throw ClaudeClientError.keychainUnavailable
        }
        return selected
    }

    static func decodeCredentials(_ data: Data, now: Date = Date()) -> Credentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        // Claude Code marks a dead refresh token with "" and records its own expiry.
        let hasRefreshToken = (oauth["refreshToken"] as? String).map { !$0.isEmpty } ?? false
        let refreshExpiry = (oauth["refreshTokenExpiresAt"] as? NSNumber)?.doubleValue
        let refreshable = hasRefreshToken
            && refreshExpiry.map { $0 > now.timeIntervalSince1970 * 1_000 } ?? true
        return Credentials(accessToken: token, expiresAt: (oauth["expiresAt"] as? NSNumber)?.doubleValue,
                           plan: oauth["subscriptionType"] as? String, refreshable: refreshable)
    }
}

private final class ClaudeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data, plan: String? = nil) throws -> CodexUsageSnapshot {
        try parse(data, identity: CodexIdentity(planType: plan), source: .claudeCode)
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
