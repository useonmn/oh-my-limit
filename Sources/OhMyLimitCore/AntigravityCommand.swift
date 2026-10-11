import Foundation
import Darwin

/// One owned, noninteractive process. Queue ownership covers all mutable state and descriptors.
final class AntigravityCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OhMyLimit.AntigravityCommand")
    private var pid: pid_t = 0
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
            // Keep only launch essentials. No inherited injected OAuth/agent/project configuration.
            let environment = ProcessInfo.processInfo.environment
            let controlled = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "CI": "1", "NO_COLOR": "1"]
            try spawn(executable: executable, arguments: arguments, environment: controlled, directory: directory)
            started = true
            let child = pid
            // Observe exit WITHOUT reaping. The zombie leader pins the pid/pgid
            // until the queue has killed remaining helpers, so a delayed signal
            // can never hit a reused pid or a different process group.
            DispatchQueue.global(qos: .utility).async {
                var info = siginfo_t()
                var status: Int32
                repeat { status = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) }
                while status == -1 && errno == EINTR
                let owned = status == 0
                self.queue.async { self.didExit(owned: owned) }
            }
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            readers.append(try reader(stdout.fileHandleForReading, isError: false))
            readers.append(try reader(stderr.fileHandleForReading, isError: true))
            timer = deadline(timeout) { self.finish(.failure(AntigravityClientError.timedOut)) }
        } catch { finish(.failure(AntigravityClientError.launchFailed)) }
    }

    private func spawn(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AntigravityClientError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AntigravityClientError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0
        else { throw AntigravityClientError.launchFailed }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        guard posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp) == 0 else {
            throw AntigravityClientError.launchFailed
        }
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

    private func didExit(owned: Bool) {
        var status: Int32 = -1
        if owned {
            // This is the last group signal and always precedes our only reap.
            kill(-pid, SIGKILL)
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            if reaped != pid { status = -1 }
        }
        exited = true
        // Exit notification can precede dispatch-read delivery. Drain final bytes before resolving.
        if result == nil {
            if !stdoutEOF { _ = drain(stdout.fileHandleForReading.fileDescriptor, isError: false) }
            if !stderrEOF { _ = drain(stderr.fileHandleForReading.fileDescriptor, isError: true) }
            finish(status == 0 ? .success(output) : .failure(AntigravityClientError.processFailed))
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
            kill(-pid, SIGTERM)
            killTimer = deadline(0.1) {
                if !self.exited { kill(-self.pid, SIGKILL) }
            }
        } else { complete() }
    }

    private func complete() {
        guard (!started || exited), var result, let continuation else { return }
        killTimer?.cancel()
        killTimer = nil
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
