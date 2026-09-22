import Foundation
import Network

/// Holds a real HTTP response open until the client cancels. Signals request and EOF events.
final class AntigravityOAuthHTTPFixture: @unchecked Sendable {
    let requests: AsyncStream<Void>
    let closed: AsyncStream<Void>
    private let requestSignal: AsyncStream<Void>.Continuation
    private let closedSignal: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "AntigravityOAuthHTTPFixture")
    private let listener: NWListener
    private let sendHeaders: Bool
    private var connection: NWConnection?
    private var readiness: CheckedContinuation<Int, any Error>?
    private var timer: DispatchSourceTimer?
    private var didSignalRequest = false

    init(sendHeaders: Bool) throws {
        (requests, requestSignal) = AsyncStream<Void>.makeStream()
        (closed, closedSignal) = AsyncStream<Void>.makeStream()
        self.sendHeaders = sendHeaders
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
                    case .ready:
                        self.readiness?.resume(returning: Int(self.listener.port!.rawValue))
                        self.readiness = nil
                    case .failed: self.stopOnQueue()
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { connection in
                    guard self.connection == nil else { connection.cancel(); return }
                    self.connection = connection
                    connection.start(queue: self.queue)
                    self.receive(data: Data())
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 5)
                timer.setEventHandler { self.stopOnQueue() }
                self.timer = timer
                timer.resume()
                self.listener.start(queue: self.queue)
            }
        }
    }

    private func receive(data: Data) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, done, error in
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= 16_384 else { self.stopOnQueue(); return }
            if !self.didSignalRequest, data.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.didSignalRequest = true
                if self.sendHeaders {
                    let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nx".utf8)
                    self.connection?.send(content: header, completion: .contentProcessed { error in
                        if error == nil { self.requestSignal.yield(()) }
                        else { self.stopOnQueue() }
                    })
                } else { self.requestSignal.yield(()) }
            }
            if done || error != nil {
                self.closedSignal.yield(())
                self.stopOnQueue()
            } else { self.receive(data: data) }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in queue.async { self.stopOnQueue(); continuation.resume() } }
    }

    private func stopOnQueue() {
        readiness?.resume(throwing: URLError(.timedOut))
        readiness = nil
        timer?.cancel()
        timer = nil
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        connection?.cancel()
        connection = nil
        requestSignal.finish()
        closedSignal.finish()
    }
}
