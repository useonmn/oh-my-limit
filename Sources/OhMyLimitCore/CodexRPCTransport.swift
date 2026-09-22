import Foundation

/// All mutable state, descriptor I/O, timers and Process callbacks are serialized on queue.
/// The unchecked conformance is confined to this queue-owned transport boundary.
final class CodexRPCTransport: @unchecked Sendable {
    enum Output: Sendable {
        case usage(CodexUsageSnapshot)
        case identity(CodexIdentity)
    }
    private enum Stage { case initialize, account, limits, loginStart }
    private let queue = DispatchQueue(label: "OhMyLimit.CodexRPC")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let executableURL: URL
    private let home: URL
    private let timeout: TimeInterval
    private let loginTimeout: TimeInterval
    private var continuation: CheckedContinuation<Output, any Error>?
    private var result: Result<Output, any Error>?
    private var onURL: (@Sendable (URL) -> Void)?
    private var started = false
    private var exited = false
    private var cancelled = false
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var requestTimer: DispatchSourceTimer?
    private var loginTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var pending: (id: Int, stage: Stage)?
    private var nextID = 0
    private var framer = CodexLineFramer()
    private var errorBytes = 0
    private var identity: CodexIdentity?
    private var loginID: String?
    private var loginCompletions: [String: Bool] = [:]
    private static let maxStderr = 1024 * 1024

    init(executableURL: URL, home: URL, timeout: TimeInterval, loginTimeout: TimeInterval) {
        self.executableURL = executableURL
        self.home = home
        self.timeout = timeout
        self.loginTimeout = loginTimeout
    }

    func run(onURL: (@Sendable (URL) -> Void)?) async throws -> Output {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.onURL = onURL
                    self.start()
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                if self.continuation != nil { self.finish(.failure(CancellationError())) }
            }
        }
    }

    private func start() {
        guard !cancelled else { finish(.failure(CancellationError())); return }
        guard timeout.isFinite, timeout > 0, loginTimeout.isFinite, loginTimeout > 0 else {
            finish(.failure(CodexClientError.timedOut)); return
        }
        guard executableURL.isFileURL, home.isFileURL else {
            finish(.failure(CodexClientError.launchFailed)); return
        }
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://",
                             "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\""]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.didExit() }
        }
        do {
            try process.run()
            started = true
            input.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
            errors.fileHandleForWriting.closeFile()
            // Avoid SIGPIPE affecting the host app if the child closes stdin mid-request.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                finish(.failure(CodexClientError.launchFailed)); return
            }
            stdoutSource = try reader(output.fileHandleForReading, isError: false)
            stderrSource = try reader(errors.fileHandleForReading, isError: true)
            try request(.initialize, method: "initialize", params: [
                "clientInfo": ["name": "oh_my_limit", "title": "Oh My Limit", "version": "1.0"],
                "capabilities": ["experimentalApi": false]
            ])
        } catch {
            finish(.failure(error as? CodexClientError ?? .launchFailed))
        }
    }

    private func reader(_ handle: FileHandle, isError: Bool) throws -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { throw CodexClientError.launchFailed }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd, isError: isError) }
        source.setCancelHandler { handle.closeFile() }
        source.resume()
        return source
    }

    private func drain(_ fd: Int32, isError: Bool) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Nonblocking bounded chunks on the owner queue; no unbounded callback backlog.
        while result == nil {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                if isError {
                    errorBytes += count
                    if errorBytes > Self.maxStderr { finish(.failure(CodexClientError.outputLimitExceeded)) }
                } else {
                    receive(Data(bytes.prefix(count)))
                }
            } else if count == 0 {
                if isError {
                    stderrSource?.cancel()
                    stderrSource = nil
                } else {
                    stdoutSource?.cancel()
                    stdoutSource = nil
                    finish(.failure(framer.hasPartialLine ? CodexClientError.malformedProtocol : .processExited))
                }
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(.failure(CodexClientError.processExited))
                return
            }
        }
    }

    private func receive(_ data: Data) {
        do {
            for line in try framer.append(data) {
                guard result == nil else { break }
                try receiveLine(line)
            }
        } catch { finish(.failure(error as? CodexClientError ?? .malformedProtocol)) }
    }

    private func receiveLine(_ data: Data) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexClientError.malformedProtocol
        }
        if let rawID = message["id"] {
            // We send numeric IDs; string IDs and responses for other requests cannot match.
            guard let number = rawID as? NSNumber, String(cString: number.objCType) != "c",
                  let pending, number == NSNumber(value: pending.id) else { return }
            guard message["method"] == nil else { throw CodexClientError.malformedProtocol }
            if let error = message["error"] as? [String: Any] {
                guard let code = error["code"] as? Int else { throw CodexClientError.malformedProtocol }
                throw CodexClientError.serverError(code: code)
            }
            guard message["error"] == nil, let payload = message["result"] as? [String: Any] else {
                throw CodexClientError.malformedProtocol
            }
            self.pending = nil
            requestTimer?.cancel()
            requestTimer = nil
            try response(pending.stage, data: JSONSerialization.data(withJSONObject: payload))
        } else if let method = message["method"] as? String {
            guard method == "account/login/completed", onURL != nil else { return }
            guard let params = message["params"] as? [String: Any] else { throw CodexClientError.malformedProtocol }
            let completion = try CodexResponseParser.decode(LoginCompletion.self, JSONSerialization.data(withJSONObject: params))
            guard let id = completion.loginId else { return }
            if let loginID {
                if id == loginID { try completeLogin(success: completion.success) }
            } else {
                guard loginCompletions.count < 64 else { throw CodexClientError.outputLimitExceeded }
                loginCompletions[id] = completion.success
            }
        } else {
            throw CodexClientError.malformedProtocol
        }
    }

    private func response(_ stage: Stage, data: Data) throws {
        switch stage {
        case .initialize:
            try send(["method": "initialized"])
            if onURL != nil {
                try request(.loginStart, method: "account/login/start", params: ["type": "chatgpt"])
            } else {
                try request(.account, method: "account/read", params: ["refreshToken": false])
            }
        case .account:
            let account = try CodexResponseParser.identity(from: data)
            if onURL != nil { finish(.success(.identity(account))) }
            else {
                identity = account
                try request(.limits, method: "account/rateLimits/read")
            }
        case .limits:
            guard let identity else { throw CodexClientError.malformedProtocol }
            finish(.success(.usage(try CodexResponseParser.usage(from: data, identity: identity))))
        case .loginStart:
            let login = try CodexResponseParser.decode(LoginStart.self, data)
            guard login.type == "chatgpt", !login.loginId.isEmpty else { throw CodexClientError.malformedProtocol }
            guard let url = Self.officialLoginURL(login.authUrl) else { throw CodexClientError.invalidLoginURL }
            loginID = login.loginId
            // The human deadline begins only after the browser flow is ready. Request
            // deadlines independently bound initialization, login/start and account/read.
            loginTimer = timer(after: loginTimeout) {
                if self.loginTimer != nil { self.finish(.failure(CodexClientError.timedOut)) }
            }
            // A synchronous callback is delivered exactly once before completion; callers
            // should enqueue browser/UI work rather than block this serial callback.
            onURL?(url)
            if let success = loginCompletions[login.loginId] { try completeLogin(success: success) }
            loginCompletions.removeAll()
        }
    }

    static func officialLoginURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.fragment == nil, let url = parts.url else { return nil }
        let path = parts.path
        let isAuthPath = path == "/oauth/authorize" || path == "/authorize"
            || (host == "chatgpt.com" && path.hasPrefix("/auth/"))
        guard isAuthPath else { return nil }
        return url
    }

    private func completeLogin(success: Bool) throws {
        guard success else { throw CodexClientError.loginFailed }
        // Duplicate completions cannot issue duplicate account/read requests.
        guard pending == nil else { return }
        loginTimer?.cancel()
        loginTimer = nil
        try request(.account, method: "account/read", params: ["refreshToken": false])
    }

    private func request(_ stage: Stage, method: String, params: [String: Any]? = nil) throws {
        nextID += 1
        pending = (nextID, stage) // Subscribe before writing, including immediate fixture replies.
        requestTimer?.cancel()
        let requestID = nextID
        requestTimer = timer(after: timeout) {
            if self.pending?.id == requestID { self.finish(.failure(CodexClientError.timedOut)) }
        }
        var message: [String: Any] = ["id": nextID, "method": method]
        if let params { message["params"] = params }
        try send(message)
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw CodexClientError.processExited }
    }

    private func timer(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func finish(_ result: Result<Output, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        requestTimer?.cancel()
        requestTimer = nil
        loginTimer?.cancel()
        loginTimer = nil
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        input.fileHandleForWriting.closeFile()
        if started && !exited {
            if process.isRunning { process.terminate() }
            // This is a production cleanup deadline, not a test synchronization delay.
            killTimer = timer(after: 0.25) {
                if !self.exited && self.process.isRunning {
                    if kill(self.process.processIdentifier, SIGKILL) != 0 && errno != ESRCH {
                        self.result = .failure(CodexClientError.processExited)
                    }
                }
            }
        } else {
            complete()
        }
    }

    private func didExit() {
        exited = true
        if result == nil {
            // Exit notifications can race readable events. Drain complete final responses first.
            if stdoutSource != nil { drain(output.fileHandleForReading.fileDescriptor, isError: false) }
            if result == nil { finish(.failure(framer.hasPartialLine ? CodexClientError.malformedProtocol : .processExited)) }
        }
        complete()
    }

    private func complete() {
        guard let result, let continuation else { return }
        killTimer?.cancel()
        killTimer = nil
        process.terminationHandler = nil
        self.continuation = nil
        onURL = nil
        framer = CodexLineFramer()
        loginCompletions.removeAll()
        continuation.resume(with: cancelled ? .failure(CancellationError()) : result)
    }

    private struct LoginStart: Decodable {
        let type: String
        let loginId: String
        let authUrl: String
    }
    private struct LoginCompletion: Decodable {
        let loginId: String?
        let success: Bool
    }
}

/// Incremental byte framing preserves UTF-8 sequences split across pipe reads.
struct CodexLineFramer {
    private var buffer = Data()
    private var received = 0
    var hasPartialLine: Bool { !buffer.isEmpty }
    private let maxLine = 1024 * 1024
    private let maxOutput = 8 * 1024 * 1024

    mutating func append(_ data: Data) throws -> [Data] {
        guard data.count <= maxOutput - received else { throw CodexClientError.outputLimitExceeded }
        received += data.count
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= maxLine else { throw CodexClientError.outputLimitExceeded }
            if !line.isEmpty && line != Data([0x0D]) { lines.append(line) }
        }
        guard buffer.count <= maxLine else { throw CodexClientError.outputLimitExceeded }
        return lines
    }
}
