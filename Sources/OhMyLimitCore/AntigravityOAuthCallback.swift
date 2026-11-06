import Foundation
import Network

/// All mutable state, listener events, connection events and cancellation run on one queue.
final class AntigravityOAuthCallback: @unchecked Sendable {
    enum ParsedRequest: Equatable { case incomplete, ignored, code(String), denied, failed, tooLarge }
    /// Browsers attach every `localhost` cookie to the callback, so the cap must leave room for large Cookie headers.
    static let maxRequestBytes = 65_536

    private let queue = DispatchQueue(label: "local.ohmylimit.antigravity.oauth.callback")
    private var listener: NWListener
    private var ipv6Reservation: Int32 = -1
    private let state: String
    private let timeout: TimeInterval
    private let ports: [UInt16]
    private let path: String
    private let redirectHost: String
    private var portIndex = 0
    private var continuation: CheckedContinuation<String, any Error>?
    private var timer: DispatchSourceTimer?
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTimers: [UUID: DispatchSourceTimer] = [:]
    private var result: Result<String, any Error>?
    private var accepted = false
    private var redirect: URL?

    init(state: String, timeout: TimeInterval = 180,
         ports: [UInt16] = [], path: String = "/callback", redirectHost: String = "127.0.0.1") throws {
        self.state = state
        self.timeout = timeout
        self.ports = ports
        self.path = path
        self.redirectHost = redirectHost
        do { listener = try Self.makeListener(port: ports.first) }
        catch { throw AntigravityOAuthError.callbackUnavailable }
    }

    private static func makeListener(port: UInt16?) throws -> NWListener {
        let parameters = NWParameters.tcp
        let ip = parameters.defaultProtocolStack.internetProtocol as! NWProtocolIP.Options
        ip.version = .v4
        let endpointPort: NWEndpoint.Port = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        return try NWListener(using: parameters)
    }

    func wait(onReady: @escaping @Sendable (URL) -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result); return }
                    self.continuation = continuation
                    self.armListener(onReady: onReady)
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + self.timeout)
                    timer.setEventHandler { self.finish(.failure(AntigravityOAuthError.timedOut)) }
                    self.timer = timer
                    timer.resume()
                    self.listener.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func armListener(onReady: @escaping @Sendable (URL) -> Void) {
        let current = listener
        listener.stateUpdateHandler = { status in
            guard self.listener === current, self.result == nil else { return }
            switch status {
            case .ready:
                guard let port = current.port, self.redirect == nil else { return }
                if self.redirectHost == "localhost" {
                    do {
                        self.ipv6Reservation = try Self.reserveIPv6(port: port.rawValue)
                    } catch { self.nextListener(onReady: onReady); return }
                }
                self.publish(port: port.rawValue, onReady: onReady)
            case .failed:
                self.nextListener(onReady: onReady)
            default: break
            }
        }
        listener.newConnectionHandler = { self.receiveNew($0) }
    }

    private static func reserveIPv6(port: UInt16) throws -> Int32 {
        // Keep the registered localhost URI for Codex/Claude. A bound but
        // non-listening ::1 socket prevents a squatter from accepting the code;
        // IPv6 connections are refused immediately so clients can try IPv4.
        // Separate Network.framework listeners contend for the same port.
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AntigravityOAuthError.callbackUnavailable }
        var onlyIPv6: Int32 = 1
        guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &onlyIPv6, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd)
            throw AntigravityOAuthError.callbackUnavailable
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = port.bigEndian
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard status == 0 else {
            Darwin.close(fd)
            throw AntigravityOAuthError.callbackUnavailable
        }
        return fd
    }

    private func publish(port: UInt16, onReady: @escaping @Sendable (URL) -> Void) {
        guard redirect == nil else { return }
        let url = URL(string: "http://\(redirectHost):\(port)\(path)")!
        redirect = url
        onReady(url)
    }

    private func nextListener(onReady: @escaping @Sendable (URL) -> Void) {
        closeListeners()
        guard result == nil, redirect == nil, portIndex + 1 < ports.count,
              let next = try? Self.makeListener(port: ports[portIndex + 1])
        else { finish(.failure(AntigravityOAuthError.callbackUnavailable)); return }
        portIndex += 1
        listener = next
        armListener(onReady: onReady)
        listener.start(queue: queue)
    }

    private func closeListeners() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        if ipv6Reservation >= 0 {
            Darwin.close(ipv6Reservation)
            ipv6Reservation = -1
        }
    }

    func redirectURI() async -> URL? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.redirect) } }
    }

    func isClosed() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.result != nil && self.connections.isEmpty && self.timer == nil) }
        }
    }

    private func receiveNew(_ connection: NWConnection) {
        guard result == nil, !accepted, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { self.close(id) }
        connectionTimers[id] = timer
        timer.resume()
        connection.start(queue: queue)
        receive(id, data: Data())
    }

    private func receive(_ id: UUID, data: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, complete, error in
            guard self.result == nil, self.connections[id] != nil else { return }
            var data = data
            if let chunk { data.append(chunk) }
            let parsed = Self.parse(data, state: self.state, path: self.path)
            if parsed == .incomplete {
                if complete || error != nil { self.close(id) }
                else { self.receive(id, data: data) }
                return
            }
            guard !self.accepted else { self.close(id); return }
            let outcome: Result<String, any Error>?
            switch parsed {
            case .code(let code): outcome = .success(code)
            case .denied: outcome = .failure(AntigravityOAuthError.userCancelled)
            case .failed, .tooLarge: outcome = .failure(AntigravityOAuthError.invalidResponse)
            default: outcome = nil
            }
            if outcome != nil { self.accepted = true }
            // Constant documents only: no auth material is reflected in HTML or headers.
            let body: String
            let status: String
            switch (parsed, outcome) {
            case (.tooLarge, _):
                body = "<!doctype html><title>Sign-in failed</title>The sign-in request was too large. Return to OhMyLimit and try again."
                status = "431 Request Header Fields Too Large"
            case (_, nil):
                body = "<!doctype html><title>Not found</title>Not found."
                status = "404 Not Found"
            default:
                body = "<!doctype html><title>Return to OhMyLimit</title>You can close this window and return to OhMyLimit."
                status = "200 OK"
            }
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                self.close(id)
                if let outcome { self.finish(outcome) }
            })
        }
    }

    private func close(_ id: UUID) {
        connectionTimers.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ outcome: Result<String, any Error>) {
        guard result == nil else { return }
        result = outcome
        timer?.cancel()
        timer = nil
        closeListeners()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        connectionTimers.values.forEach { $0.cancel() }
        connectionTimers.removeAll()
        let pending = continuation
        continuation = nil
        pending?.resume(with: outcome)
    }

    static func parse(_ data: Data, state: String, path: String = "/callback") -> ParsedRequest {
        guard data.count <= maxRequestBytes else { return oversized(data, state: state, path: path) }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard end.upperBound == data.endIndex,
              let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .ignored }
        let lines = header.components(separatedBy: "\r\n")
        guard let target = callbackQuery(lines[0], path: path) else { return .ignored }
        var contentLengths = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .ignored }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), name != "transfer-encoding" else { return .ignored }
            if name == "content-length" {
                contentLengths += 1
                guard contentLengths == 1, value == "0" else { return .ignored }
            }
        }
        guard let fields = callbackFields(target, state: state) else { return .ignored }
        if let codes = fields["code"] {
            guard codes.count == 1, fields["error"] == nil, !codes[0].isEmpty,
                  codes[0].utf8.count <= 8192, codes[0].utf8.allSatisfy({ (33...126).contains($0) }) else { return .ignored }
            return .code(codes[0])
        }
        guard let errors = fields["error"], errors.count == 1, !errors[0].isEmpty else { return .ignored }
        return errors[0] == "access_denied" ? .denied : .failed
    }

    /// Over the cap, fail the login only for a well-formed GET to the callback path carrying the matching state;
    /// anything else stays ignored so unrelated pages cannot abort a login.
    private static func oversized(_ data: Data, state: String, path: String) -> ParsedRequest {
        guard let lineEnd = data.range(of: Data("\r\n".utf8)),
              let line = String(data: data[..<lineEnd.lowerBound], encoding: .utf8),
              let target = callbackQuery(line, path: path),
              callbackFields(target, state: state) != nil else { return .ignored }
        return .tooLarge
    }

    /// Returns the query of a `GET <path>?<query> HTTP/1.x` request line, or nil.
    private static func callbackQuery(_ line: String, path: String) -> Substring? {
        let request = line.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", ["HTTP/1.1", "HTTP/1.0"].contains(request[2]),
              request[1].utf8.allSatisfy({ (33...126).contains($0) }), !request[1].contains("#") else { return nil }
        let target = request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard target.count == 2, target[0] == path else { return nil }
        return target[1]
    }

    /// Decodes the query, requiring exactly one constant-time-matching `state`.
    private static func callbackFields(_ query: Substring, state: String) -> [String: [String]]? {
        var fields: [String: [String]] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
            fields[name, default: []].append(value)
        }
        guard let states = fields["state"], states.count == 1, constantTimeEqual(states[0], state) else { return nil }
        return fields
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
