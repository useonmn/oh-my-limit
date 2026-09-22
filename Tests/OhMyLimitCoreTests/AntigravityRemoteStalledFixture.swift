import Foundation
import Network

/// Accepts requests without replying, for real URLSession deadline/cancellation tests.
final class AntigravityRemoteStalledFixture: @unchecked Sendable {
    let arrivals = AsyncStream<String>.makeStream()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AntigravityRemoteStalledFixture")
    private var connections: [NWConnection] = []
    private var readiness: CheckedContinuation<Int, any Error>?
    private var timer: DispatchSourceTimer?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readiness = continuation
                self.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.finishReady(.success(Int(self.listener.port!.rawValue)))
                    case .failed(let error): self.finishReady(.failure(error))
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { connection in
                    self.connections.append(connection)
                    connection.start(queue: self.queue)
                    self.receive(connection, data: Data())
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 5)
                timer.setEventHandler { self.finishReady(.failure(URLError(.timedOut))) }
                self.timer = timer
                timer.resume()
                self.listener.start(queue: self.queue)
            }
        }
    }

    private func finishReady(_ result: Result<Int, any Error>) {
        timer?.cancel()
        timer = nil
        readiness?.resume(with: result)
        readiness = nil
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= 16_384 else { connection.cancel(); return }
            let request = String(decoding: data, as: UTF8.self)
            if request.contains("\r\n\r\n") { self.arrivals.continuation.yield(request) }
            else if !complete && error == nil { self.receive(connection, data: data) }
            else { connection.cancel() }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timer?.cancel()
                self.listener.cancel()
                self.connections.forEach { $0.cancel() }
                self.listener.newConnectionHandler = nil
                self.listener.stateUpdateHandler = nil
                self.arrivals.continuation.finish()
                continuation.resume()
            }
        }
    }
}
