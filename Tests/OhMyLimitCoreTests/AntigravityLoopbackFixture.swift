import Foundation
import Network

/// A real loopback HTTP peer. Readiness is NWListener.ready, never a delay or polling loop.
final class AntigravityLoopbackFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AntigravityLoopbackFixture")
    private let listener: NWListener
    private let handler: @Sendable (String) -> String
    private var connections: [NWConnection] = []
    private var received: [String] = []
    private var readiness: CheckedContinuation<Int, any Error>?
    private var timer: DispatchSourceTimer?

    init(handler: @escaping @Sendable (String) -> String) throws {
        self.handler = handler
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
            if request.contains("\r\n\r\n") {
                self.received.append(request)
                let response = self.handler(request)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete && error == nil { self.receive(connection, data: data) }
            else { connection.cancel() }
        }
    }

    func requests() async -> [String] {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.received) } }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timer?.cancel()
                self.listener.cancel()
                self.connections.forEach { $0.cancel() }
                self.listener.newConnectionHandler = nil
                self.listener.stateUpdateHandler = nil
                continuation.resume()
            }
        }
    }

    static func response(_ body: String, status: Int = 200, headers: String = "") -> String {
        "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\(headers)\r\n\(body)"
    }
}
