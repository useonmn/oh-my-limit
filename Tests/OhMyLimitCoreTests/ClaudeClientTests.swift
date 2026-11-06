import Foundation
import Testing
@testable import OhMyLimitCore

struct ClaudeClientTests {
    @Test(arguments: [false, true]) func realUsageTransportCapsDeclaredAndChunkedBodies(_ chunked: Bool) async throws {
        let server = try AntigravityLoopbackFixture { _ in
            let body = String(repeating: "x", count: 1_048_577)
            if chunked {
                return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n100001\r\n\(body)\r\n0\r\n\r\n"
            }
            return AntigravityLoopbackFixture.response(body)
        }
        let port = try await server.start()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!)
        await #expect(throws: ClaudeClientError.invalidResponse) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        await server.stop()
    }

    @Test func realUsageTransportAcceptsExactLimitAndRejectsRedirects() async throws {
        let server = try AntigravityLoopbackFixture { request in
            if request.hasPrefix("GET /redirect ") {
                return AntigravityLoopbackFixture.response("", status: 302, headers: "Location: /usage\r\n")
            }
            let json = #"{"seven_day":{"utilization":42}}"#
            return AntigravityLoopbackFixture.response(json + String(repeating: " ", count: 1_048_576 - json.utf8.count))
        }
        let port = try await server.start()
        do {
            let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!)
            let usage = try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
            #expect(usage.windows.first?.usedPercent == 42)
            let redirect = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/redirect")!)
            await #expect(throws: ClaudeClientError.requestFailed) {
                try await redirect.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
            }
            #expect(await server.requests().count == 2)
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test func cancelledUsageRequestClosesConnection() async throws {
        let server = try AntigravityOAuthHTTPFixture(sendHeaders: true)
        let port = try await server.start()
        var requests = server.requests.makeAsyncIterator()
        var closed = server.closed.makeAsyncIterator()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!)
        let task = Task { try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity()) }
        defer { task.cancel() }
        do {
            _ = try #require(await requests.next())
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            _ = try #require(await closed.next())
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test func usageRequestCarriesOAuthBetaHeader() async throws {
        let server = try AntigravityLoopbackFixture { request in
            let beta = request.lowercased().contains("\r\nanthropic-beta: oauth-2025-04-20\r\n")
            return beta ? AntigravityLoopbackFixture.response(#"{"seven_day":{"utilization":7}}"#)
                : AntigravityLoopbackFixture.response("", status: 401)
        }
        let port = try await server.start()
        do {
            let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!)
            let usage = try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
            #expect(usage.windows.first?.usedPercent == 7)
            let request = try #require(await server.requests().first)
            #expect(request.lowercased().contains("\r\nanthropic-beta: oauth-2025-04-20\r\n"))
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test(arguments: [("Retry-After: 120\r\n", 120.0 as TimeInterval?), ("", nil)])
    func rateLimitKeepsRetryAfter(_ header: String, _ expected: TimeInterval?) async throws {
        let server = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response("", status: 429, headers: header)
        }
        let port = try await server.start()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!)
        await #expect(throws: ClaudeClientError.rateLimited(retryAfter: expected)) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        await server.stop()
    }

    @Test func retryAfterParsesHTTPDateAndClamps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(ClaudeClient.retryAfter(formatter.string(from: now.addingTimeInterval(90)), now: now) == 90)
        #expect(ClaudeClient.retryAfter(formatter.string(from: now.addingTimeInterval(-90)), now: now) == 0)
        #expect(ClaudeClient.retryAfter("999999", now: now) == 3600)
        #expect(ClaudeClient.retryAfter("soon", now: now) == nil)
        #expect(ClaudeClient.retryAfter(nil, now: now) == nil)
    }

    @Test func newerLimitsPreserveWeeklyAndModelBoundaries() throws {
        let data = Data(#"""
        {"limits":[
          {"kind":"session","percent":0,"resets_at":"2026-09-23T08:10:00.126147+00:00"},
          {"kind":"weekly_all","percent":62,"resets_at":"2026-09-28T06:00:00Z"},
          {"kind":"weekly_scoped","percent":100,"scope":{"model":{"display_name":"Opus"}}},
          {"kind":"other","percent":99}
        ]}
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data, plan: "max")
        #expect(snapshot.windows.map(\.id) == ["claude.session", "claude.weekly", "claude.model.Opus"])
        #expect(snapshot.windows.map(\.usedPercent) == [0, 62, 100])
        #expect(snapshot.windows[0].resetsAt != nil)
        #expect(snapshot.windows[1].resetsAt != nil)
        #expect(snapshot.identity.planType == "max")
        let profile = AccountProfile(name: "Claude", homePath: "/tmp/claude", isManaged: false, provider: .claude)
        #expect(AccountState(profile: profile, snapshot: snapshot).menuWindow?.id == "claude.weekly")
    }

    @Test func legacyWindowsDoNotInventMissingUsage() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":105,"resets_at":null},"seven_day":{"utilization":null}}
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data)
        #expect(snapshot.windows[0].usedPercent == 105)
        #expect(snapshot.windows[0].usageKnown)
        #expect(!snapshot.windows[1].usageKnown)
        let profile = AccountProfile(name: "Claude", homePath: "/tmp/claude", isManaged: false, provider: .claude)
        #expect(AccountState(profile: profile, snapshot: snapshot).menuWindow?.id == "claude.session")
        #expect(throws: ClaudeClientError.self) {
            try ClaudeUsageParser.parse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
        }
    }

    @Test func unknownNewWeeklyQuotaUsesKnownLegacyWeeklyValue() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_all","percent":null}],"seven_day":{"utilization":44}}"#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == "claude.weekly")
        #expect(snapshot.windows[0].usedPercent == 44)
        #expect(snapshot.windows[0].usageKnown)
    }
}
