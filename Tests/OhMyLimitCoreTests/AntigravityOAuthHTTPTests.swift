import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityOAuthHTTPTests {
    @Test(arguments: [false, true]) func cancellationClosesRealHTTPConnection(sendHeaders: Bool) async throws {
        let server = try AntigravityOAuthHTTPFixture(sendHeaders: sendHeaders)
        let port = try await server.start()
        var requests = server.requests.makeAsyncIterator()
        var closed = server.closed.makeAsyncIterator()
        let client = AntigravityOAuthClient(configuration: .init(clientID: "fixture", clientSecret: "fixture"), transport: { input in
            var request = input
            request.url = URL(string: "http://127.0.0.1:\(port)/token")!
            return try await AntigravityOAuthHTTPS.send(request)
        })
        let task = Task { try await client.refresh(oauthCredentials()) }
        defer { task.cancel() }
        do {
            _ = try #require(await requests.next())
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            _ = try #require(await closed.next())
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test func realTransportRefusesRedirectsAndDoesNotReuseCookies() async throws {
        let server = try AntigravityLoopbackFixture { request in
            if request.hasPrefix("GET /redirect ") {
                return AntigravityLoopbackFixture.response("redirect", status: 302, headers: "Location: /must-not-follow\r\nSet-Cookie: oauthfixture=private\r\n")
            }
            return AntigravityLoopbackFixture.response("ok")
        }
        let port = try await server.start()
        do {
            let root = URL(string: "http://127.0.0.1:\(port)")!
            let (_, redirect) = try await AntigravityOAuthHTTPS.send(URLRequest(url: root.appendingPathComponent("redirect")))
            #expect(redirect.statusCode == 302)
            let (body, response) = try await AntigravityOAuthHTTPS.send(URLRequest(url: root.appendingPathComponent("next")))
            #expect(response.statusCode == 200)
            #expect(String(decoding: body, as: UTF8.self) == "ok")
            let requests = await server.requests()
            #expect(requests.count == 2)
            #expect(!requests.contains { $0.contains("/must-not-follow") })
            #expect(!requests.contains { $0.lowercased().contains("\r\ncookie:") })
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test(arguments: [false, true]) func realTransportBoundsDeclaredAndStreamedBodies(chunked: Bool) async throws {
        let server = try AntigravityLoopbackFixture { _ in
            if chunked {
                let body = String(repeating: "x", count: 65_537)
                return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n10001\r\n\(body)\r\n0\r\n\r\n"
            }
            return AntigravityLoopbackFixture.response(String(repeating: "x", count: 65_537))
        }
        let port = try await server.start()
        await #expect(throws: AntigravityOAuthError.invalidResponse) {
            try await AntigravityOAuthHTTPS.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        }
        await server.stop()
    }

    @Test func realTransportAcceptsExactlyTheResponseLimit() async throws {
        let server = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response(String(repeating: "x", count: 65_536)) }
        let port = try await server.start()
        do {
            let (body, _) = try await AntigravityOAuthHTTPS.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
            #expect(body.count == 65_536)
        } catch { await server.stop(); throw error }
        await server.stop()
    }
}
