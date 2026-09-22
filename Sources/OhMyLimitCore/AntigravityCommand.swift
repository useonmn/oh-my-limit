import Foundation
import Darwin

/// One owned, noninteractive process. Queue ownership covers all mutable state and descriptors.
final class AntigravityCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OhMyLimit.AntigravityCommand")
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var readers: [DispatchSourceRead] = []
    private var timer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var output = Data()
    private var errorCount = 0
    private var stdoutEOF = false
    private var stderrEOF = false
    private var cancelled = false
    private var started = false
    private var exited = false
    private var directory: URL?
    private var onOutput: (@Sendable (Data) -> Void)?
    private static let limit = 1_048_576

    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        let command = AntigravityCommand()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let data = try await withCheckedThrowingContinuation { continuation in
                command.queue.async {
                    command.continuation = continuation
                    command.onOutput = onOutput
                    command.start(executable: executable, arguments: arguments, timeout: timeout)
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: {
            command.queue.async {
                command.cancelled = true
                if command.continuation != nil { command.finish(.failure(CancellationError())) }
            }
        }
    }

    private func start(executable: URL, arguments: [String], timeout: TimeInterval) {
        guard !cancelled else { finish(.failure(CancellationError())); return }
        guard timeout.isFinite, timeout > 0 else { finish(.failure(AntigravityClientError.timedOut)); return }
        guard executable.isFileURL else { finish(.failure(AntigravityClientError.launchFailed)); return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OhMyLimit-agy-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            process.currentDirectoryURL = directory
            process.executableURL = executable
            process.arguments = arguments
            // Keep only launch essentials. No inherited injected OAuth/agent/project configuration.
            let environment = ProcessInfo.processInfo.environment
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "CI": "1", "NO_COLOR": "1"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.didExit() }
            }
            try process.run()
            started = true
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            readers.append(try reader(stdout.fileHandleForReading, isError: false))
            readers.append(try reader(stderr.fileHandleForReading, isError: true))
            timer = deadline(timeout) { self.finish(.failure(AntigravityClientError.timedOut)) }
        } catch { finish(.failure(AntigravityClientError.launchFailed)) }
    }

    private func reader(_ handle: FileHandle, isError: Bool) throws -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { throw AntigravityClientError.launchFailed }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            if self?.drain(fd, isError: isError) == true { source?.cancel() }
        }
        source.setCancelHandler { handle.closeFile() }
        source.resume()
        return source
    }

    /// Returns true at EOF. A bounded turn prevents continuous output from starving cancellation.
    private func drain(_ fd: Int32, isError: Bool) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<128 where result == nil {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                if isError { errorCount += count }
                else {
                    guard output.count + count <= Self.limit else { finish(.failure(AntigravityClientError.outputLimitExceeded)); return true }
                    let chunk = Data(bytes.prefix(count))
                    output.append(chunk)
                    onOutput?(chunk)
                }
                if errorCount > Self.limit { finish(.failure(AntigravityClientError.outputLimitExceeded)); return true }
            } else if count == 0 {
                if isError { stderrEOF = true } else { stdoutEOF = true }
                return true
            }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            else if errno != EINTR { finish(.failure(AntigravityClientError.processFailed)); return true }
        }
        return result != nil
    }

    private func didExit() {
        exited = true
        // Exit notification can precede dispatch-read delivery. Drain final bytes before resolving.
        if result == nil {
            if !stdoutEOF { _ = drain(stdout.fileHandleForReading.fileDescriptor, isError: false) }
            if !stderrEOF { _ = drain(stderr.fileHandleForReading.fileDescriptor, isError: true) }
            finish(process.terminationStatus == 0 ? .success(output) : .failure(AntigravityClientError.processFailed))
        }
        complete()
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        timer?.cancel()
        timer = nil
        readers.forEach { $0.cancel() }
        readers.removeAll()
        if started && !exited {
            if process.isRunning { process.terminate() }
            killTimer = deadline(0.1) {
                if !self.exited { kill(self.process.processIdentifier, SIGKILL) }
            }
        } else { complete() }
    }

    private func complete() {
        guard (!started || exited), var result, let continuation else { return }
        killTimer?.cancel()
        killTimer = nil
        process.terminationHandler = nil
        self.continuation = nil
        if !started {
            stdout.fileHandleForReading.closeFile(); stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForReading.closeFile(); stderr.fileHandleForWriting.closeFile()
        }
        if let directory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { result = .failure(AntigravityClientError.cleanupFailed) }
        }
        continuation.resume(with: result)
    }

    private func deadline(_ seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }
}
