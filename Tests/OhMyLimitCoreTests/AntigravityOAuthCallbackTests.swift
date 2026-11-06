import Foundation
import Network
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityOAuthCallbackTests {
    @Test(.timeLimit(.minutes(1))) func localhostGuardsIPv6AndServesCallbackOverIPv4() async throws {
        let callback = try AntigravityOAuthCallback(state: "expected", timeout: 5, redirectHost: "localhost")
        let urls = AsyncStream<URL>.makeStream()
        let task = Task {
            defer { urls.continuation.finish() }
            return try await callback.wait { urls.continuation.yield($0) }
        }
        defer { task.cancel() }
        var iterator = urls.stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        #expect(url.host == "localhost")
        let squatter = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(squatter) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = UInt16(url.port!).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(squatter, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        #expect(bound == -1 && errno == EADDRINUSE)
        let ipv4 = try await oauthRawRequest(url, fragments: ["GET /favicon.ico HTTP/1.1\r\n\r\n"])
        #expect(ipv4.contains("404"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let target = URL(string: "\(url.absoluteString)?state=expected&code=localhost-code")!
        var request = URLRequest(url: target)
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await task.value == "localhost-code")
        #expect(await callback.isClosed())
    }

    @Test func occupiedIPv6PortPreventsPublishingLocalhostRedirect() async throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        #expect(named == 0)
        let port = UInt16(bigEndian: address.sin6_port)
        let callback = try AntigravityOAuthCallback(state: "s", timeout: 5, ports: [port], redirectHost: "localhost")
        await #expect(throws: AntigravityOAuthError.callbackUnavailable) {
            try await callback.wait { _ in Issue.record("Must own both addresses before opening the browser") }
        }
        #expect(await callback.redirectURI() == nil)
        #expect(await callback.isClosed())
    }

    @Test func parserRequiresUnambiguousMatchingStateAndGET() {
        let state = "expected"
        func parse(_ target: String, method: String = "GET", extra: String = "") -> AntigravityOAuthCallback.ParsedRequest {
            AntigravityOAuthCallback.parse(Data("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(extra)\r\n".utf8), state: state)
        }
        #expect(parse("/callback?state=expected&code=good%2B%26%25") == .code("good+&%"))
        #expect(parse("/callback?state=expected&error=access_denied") == .denied)
        for target in ["/favicon.ico", "/callback?state=foreign&error=access_denied", "/callback?code=c", "/callback?state=expected&state=expected&code=c", "/callback?state=expected&code=a&code=b", "/callback?state=expected&code=c&error=access_denied", "/callback?state=expected&code=", "http://evil.invalid/callback?state=expected&code=c", "/callback?state=expected&code=%ZZ"] {
            #expect(parse(target) == .ignored)
        }
        #expect(parse("/callback?state=expected&code=c", method: "POST") == .ignored)
        #expect(parse("/callback?state=expected&code=c", extra: "Content-Length: 1\r\n") == .ignored)
        #expect(parse("/callback?state=expected&code=c", extra: "Transfer-Encoding: chunked\r\n") == .ignored)
        #expect(AntigravityOAuthCallback.parse(Data("GET /callback?state=expected".utf8), state: state) == .incomplete)
        let oversize = AntigravityOAuthCallback.maxRequestBytes + 1
        #expect(AntigravityOAuthCallback.parse(Data(repeating: 65, count: oversize), state: state) == .ignored)
        let cookie = "Cookie: big=\(String(repeating: "x", count: oversize))\r\n"
        #expect(parse("/callback?state=expected&code=c", extra: cookie) == .tooLarge)
        #expect(parse("/callback?state=foreign&code=c", extra: cookie) == .ignored)
        #expect(parse("/favicon.ico", extra: cookie) == .ignored)
        #expect(parse("/callback?state=expected&code=c", method: "POST", extra: cookie) == .ignored)
    }

    @Test func fragmentedCallbackSurvivesForeignRequestsAndReturnsConstantHTML() async throws {
        let callback = try AntigravityOAuthCallback(state: "expected", timeout: 5)
        let (ready, receiver) = AsyncStream<URL>.makeStream()
        let login = Task { defer { receiver.finish() }; return try await callback.wait { receiver.yield($0) } }
        defer { login.cancel() }
        var iterator = ready.makeAsyncIterator()
        let url = try #require(await iterator.next())
        #expect(url.host == "127.0.0.1")
        #expect(url.path == "/callback")
        let unrelated = try await oauthRawRequest(url, fragments: ["GET /favicon.ico HTTP/1.1\r\n\r\n"])
        #expect(unrelated.contains("404"))
        _ = try await oauthRawRequest(url, fragments: ["GET /callback?state=foreign&error=access_denied HTTP/1.1\r\n\r\n"])
        let response = try await oauthRawRequest(url, fragments: ["GET /call", "back?state=expected&code=fixture-code HTTP/1.1\r\nHost: 127.0.0.1\r\n", "\r\n"])
        #expect(try await login.value == "fixture-code")
        #expect(response.contains("200 OK"))
        #expect(!response.contains("fixture-code"))
        #expect(!response.contains("expected"))
        #expect(await callback.isClosed())
    }

    @Test func matchingDenialCancellationAndTimeoutCloseResources() async throws {
        let denied = try AntigravityOAuthCallback(state: "s", timeout: 5)
        let (stream, continuation) = AsyncStream<URL>.makeStream()
        let task = Task { defer { continuation.finish() }; return try await denied.wait { continuation.yield($0) } }
        defer { task.cancel() }
        var iterator = stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        _ = try await oauthRawRequest(url, fragments: ["GET /callback?state=s&error=access_denied HTTP/1.1\r\n\r\n"])
        await #expect(throws: AntigravityOAuthError.userCancelled) { try await task.value }
        #expect(await denied.isClosed())

        let cancelled = try AntigravityOAuthCallback(state: "s", timeout: 5)
        let (cancelReady, cancelSignal) = AsyncStream<URL>.makeStream()
        let cancelTask = Task { defer { cancelSignal.finish() }; return try await cancelled.wait { cancelSignal.yield($0) } }
        defer { cancelTask.cancel() }
        var cancelIterator = cancelReady.makeAsyncIterator()
        _ = try #require(await cancelIterator.next())
        cancelTask.cancel()
        await #expect(throws: CancellationError.self) { try await cancelTask.value }
        #expect(await cancelled.isClosed())

        let expired = try AntigravityOAuthCallback(state: "s", timeout: 0)
        await #expect(throws: AntigravityOAuthError.timedOut) { try await expired.wait { _ in } }
        #expect(await expired.isClosed())
    }

    @Test func callbackAcceptsLargeLocalhostCookiesAndFailsFastBeyondCap() async throws {
        let accepted = try AntigravityOAuthCallback(state: "s", timeout: 30, redirectHost: "localhost")
        let (ready, signal) = AsyncStream<URL>.makeStream()
        let login = Task { defer { signal.finish() }; return try await accepted.wait { signal.yield($0) } }
        defer { login.cancel() }
        var iterator = ready.makeAsyncIterator()
        let url = try #require(await iterator.next())
        let cookie = "Cookie: dev=\(String(repeating: "c", count: 30_000))\r\n"
        let response = try await oauthRawRequest(url, fragments: ["GET /callback?state=s&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n", cookie, "\r\n"])
        #expect(response.contains("200 OK"))
        #expect(try await login.value == "fixture-code")

        let rejected = try AntigravityOAuthCallback(state: "s", timeout: 30, redirectHost: "localhost")
        let (rejectReady, rejectSignal) = AsyncStream<URL>.makeStream()
        let rejectLogin = Task { defer { rejectSignal.finish() }; return try await rejected.wait { rejectSignal.yield($0) } }
        defer { rejectLogin.cancel() }
        var rejectIterator = rejectReady.makeAsyncIterator()
        let rejectURL = try #require(await rejectIterator.next())
        let huge = "Cookie: dev=\(String(repeating: "c", count: AntigravityOAuthCallback.maxRequestBytes))\r\n"
        // The server answers and closes mid-upload, so the peer may see a reset instead of the page.
        _ = try? await oauthRawRequest(rejectURL, fragments: ["GET /callback?state=s&code=fixture-code HTTP/1.1\r\nHost: localhost\r\n", huge, "\r\n"])
        await #expect(throws: AntigravityOAuthError.invalidResponse) { try await rejectLogin.value }
        #expect(await rejected.isClosed())
    }

    @Test func loginUsesReadyListenerAndOfflinePKCEAuthorization() async throws {
        let client = AntigravityOAuthClient(configuration: .init(clientID: "fixture-client", clientSecret: "fixture-secret"), transport: { request in
            if request.url?.path == "/token" {
                let form = oauthForm(request.httpBody!)
                #expect(form["code"] == "fixture-code")
                #expect(form["code_verifier"]?.count == 43)
                return oauthResponse(request, body: #"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#)
            }
            return oauthResponse(request, body: #"{"id":"google-123","email":"person@example.invalid"}"#)
        })
        let (urls, signal) = AsyncStream<URL>.makeStream()
        let task = Task { defer { signal.finish() }; return try await client.login { signal.yield($0) } }
        defer { task.cancel() }
        var iterator = urls.makeAsyncIterator()
        let authorization = try #require(await iterator.next())
        let components = try #require(URLComponents(url: authorization, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        #expect(authorization.scheme == "https")
        #expect(authorization.host == "accounts.google.com")
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"]?.count == 43)
        #expect(items["state"]?.count == 43)
        #expect(items["scope"] == AntigravityOAuthConfiguration.scopes.joined(separator: " "))
        let redirect = try #require(URL(string: items["redirect_uri"]!))
        _ = try await oauthRawRequest(redirect, fragments: ["GET /callback?state=\(items["state"]!)&code=fixture-code HTTP/1.1\r\n\r\n"])
        #expect(try await task.value.accountID == "google-123")
    }
}

/// Real TCP fragments; every send awaits contentProcessed, with no sleeps or polling.
func oauthRawRequest(_ url: URL, fragments: [String]) async throws -> String {
    let peer = OAuthTCPPeer(port: UInt16(url.port!), fragments: fragments)
    return try await peer.run()
}

private final class OAuthTCPPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OAuthTCPPeer")
    private let connection: NWConnection
    private let fragments: [String]
    private var continuation: CheckedContinuation<String, any Error>?
    private var timer: DispatchSourceTimer?
    private var response = Data()

    init(port: UInt16, fragments: [String]) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.fragments = fragments
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.send(0); self.receive()
                    case .failed(let error): self.finish(.failure(error))
                    default: break
                    }
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 5)
                timer.setEventHandler { self.finish(.failure(URLError(.timedOut))) }
                self.timer = timer
                timer.resume()
                self.connection.start(queue: self.queue)
            }
        }
    }

    private func send(_ index: Int) {
        guard index < fragments.count else { return }
        connection.send(content: Data(fragments[index].utf8), completion: .contentProcessed { error in
            if let error { self.finish(.failure(error)) } else { self.send(index + 1) }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { bytes, _, done, error in
            if let bytes { self.response.append(bytes) }
            if let error { self.finish(.failure(error)) }
            else if done { self.finish(.success(String(decoding: self.response, as: UTF8.self))) }
            else { self.receive() }
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
