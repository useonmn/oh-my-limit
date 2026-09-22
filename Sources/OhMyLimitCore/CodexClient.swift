import Foundation

/// Each operation owns a separate app-server process and its explicit CODEX_HOME.
public struct CodexClient: Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let loginTimeout: TimeInterval

    public init(executableURL: URL, timeout: TimeInterval = 20) {
        self.init(executableURL: executableURL, timeout: timeout, loginTimeout: 300)
    }

    init(executableURL: URL, timeout: TimeInterval, loginTimeout: TimeInterval) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.loginTimeout = loginTimeout
    }

    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        // Ignore relative PATH entries: a GUI launch must not execute a cwd-controlled binary.
        var candidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        candidates += [
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex"
        ]
        return candidates.first(where: {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
    }

    public func fetchUsage(home: URL) async throws -> CodexUsageSnapshot {
        let session = CodexRPCTransport(executableURL: executableURL, home: home,
                                        timeout: timeout, loginTimeout: loginTimeout)
        let result = try await session.run(onURL: nil)
        guard case .usage(let snapshot) = result else { throw CodexClientError.malformedProtocol }
        return snapshot
    }

    /// The URL callback runs synchronously on a background queue. Enqueue UI work and
    /// return promptly. Browser completion has its own 300-second deadline.
    public func login(home: URL, onURL: @escaping @Sendable (URL) -> Void) async throws -> CodexIdentity {
        let session = CodexRPCTransport(executableURL: executableURL, home: home,
                                        timeout: timeout, loginTimeout: loginTimeout)
        let result = try await session.run(onURL: onURL)
        guard case .identity(let identity) = result else { throw CodexClientError.malformedProtocol }
        return identity
    }
}
