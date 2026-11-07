import Foundation
import os
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
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!, sleep: { _ in
            Issue.record("429 must not be retried within one fetch")
        })
        await #expect(throws: ClaudeClientError.rateLimited(retryAfter: expected)) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        #expect(await server.requests().count == 1)
        await server.stop()
    }

    @Test func transientServerErrorIsRetriedWithBackoff() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let server = try AntigravityLoopbackFixture { _ in
            let attempt = attempts.withLock { count in count += 1; return count }
            return attempt < 3 ? AntigravityLoopbackFixture.response("", status: 503)
                : AntigravityLoopbackFixture.response(#"{"seven_day":{"utilization":12}}"#)
        }
        let port = try await server.start()
        let delays = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!, sleep: { delay in
            delays.withLock { $0.append(delay) }
        })
        do {
            let usage = try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
            #expect(usage.windows.first?.usedPercent == 12)
            #expect(await server.requests().count == 3)
            #expect(delays.withLock { $0 } == [.milliseconds(500), .milliseconds(1000)])
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test(arguments: [
        ("", 503, 3),
        ("Retry-After: 60\r\n", 503, 1),
        ("", 501, 1),
        ("", 404, 1),
    ])
    func failingStatusesStopAfterBoundedAttempts(_ header: String, _ status: Int, _ requests: Int) async throws {
        let server = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response("", status: status, headers: header)
        }
        let port = try await server.start()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!, sleep: { _ in })
        await #expect(throws: ClaudeClientError.requestFailed) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        #expect(await server.requests().count == requests)
        await server.stop()
    }

    @Test(arguments: [
        ("text/html", "<html>sign in to Wi-Fi</html>"),
        ("application/json", "   "),
    ])
    func nonJSONSuccessBodyIsANetworkFailureWithoutRetry(_ contentType: String, _ body: String) async throws {
        let server = try AntigravityLoopbackFixture { _ in
            "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }
        let port = try await server.start()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!, sleep: { _ in })
        await #expect(throws: ClaudeClientError.requestFailed) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        #expect(await server.requests().count == 1)
        await server.stop()
    }

    @Test(arguments: [#"{"seven_d"#, #"{"five_hour":null,"seven_day":null}"#])
    func garbledOrEmptyJSONIsRetriedThenInvalid(_ body: String) async throws {
        let server = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response(body) }
        let port = try await server.start()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!, sleep: { _ in })
        await #expect(throws: ClaudeClientError.invalidResponse) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        #expect(await server.requests().count == ClaudeClient.maxAttempts)
        await server.stop()
    }

    @Test func cancellationDuringRetryWaitStopsFetch() async throws {
        let server = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response("", status: 502) }
        let port = try await server.start()
        let client = ClaudeClient(usageURL: URL(string: "http://127.0.0.1:\(port)/usage")!, sleep: { _ in
            throw CancellationError()
        })
        await #expect(throws: CancellationError.self) {
            try await client.fetchUsage(accessToken: "fixture", identity: CodexIdentity())
        }
        #expect(await server.requests().count == 1)
        await server.stop()
    }

    @Test func retryDelayHonorsRetryAfterWithinCap() {
        #expect(ClaudeClient.retryDelay(attempt: 0, retryAfter: nil) == 0.5)
        #expect(ClaudeClient.retryDelay(attempt: 1, retryAfter: nil) == 1)
        #expect(ClaudeClient.retryDelay(attempt: 0, retryAfter: 2) == 2)
        #expect(ClaudeClient.retryDelay(attempt: 1, retryAfter: 0.2) == 1)
        #expect(ClaudeClient.retryDelay(attempt: 0, retryAfter: 6) == nil)
        #expect(ClaudeClient.isTransient(URLError(.networkConnectionLost)))
        #expect(ClaudeClient.isTransient(URLError(.cannotConnectToHost)))
        #expect(!ClaudeClient.isTransient(URLError(.timedOut)))
        #expect(!ClaudeClient.isTransient(URLError(.serverCertificateUntrusted)))
        #expect(!ClaudeClient.isTransient(ClaudeClientError.invalidResponse))
    }

    @Test func extraUsageSpendBecomesCredits() throws {
        let data = Data(#"""
        {"seven_day":{"utilization":30},
         "spend":{"enabled":true,"used":{"amount_minor":1234,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":5000,"currency":"usd","exponent":2}},
         "extra_usage":{"is_enabled":true,"monthly_limit":9900,"used_credits":1}}
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data)
        #expect(snapshot.credits == "$12.34 / $50.00")
        #expect(snapshot.windows.map(\.id) == ["claude.weekly"])
    }

    private func extraUsage(_ json: String) throws -> String? {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ClaudeUsageParser.extraUsage(root)
    }

    @Test func extraUsageLegacyAndUncappedForms() throws {
        #expect(try extraUsage(#"{"extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":250}}"#)
            == "$2.50 / $20.00")
        #expect(try extraUsage(
            #"{"extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":7,"decimal_places":0}}"#
        ) == "$7.00")
        #expect(try extraUsage(#"{"spend":null,"extra_usage":{"is_enabled":true,"monthly_limit":100,"used_credits":5}}"#)
            == "$0.05 / $1.00")
        #expect(try extraUsage(
            #"{"spend":{"enabled":true,"used":{"amount_minor":99,"currency":"USD","exponent":2},"limit":null}}"#
        ) == "$0.99")
    }

    @Test(arguments: [
        // Disabled spend.
        #"{"spend":{"enabled":false,"used":{"amount_minor":100,"currency":"USD","exponent":2},"limit":null}}"#,
        // Missing limit key.
        #"{"spend":{"enabled":true,"used":{"amount_minor":100,"currency":"USD","exponent":2}}}"#,
        // Non-USD.
        #"{"spend":{"enabled":true,"used":{"amount_minor":100,"currency":"EUR","exponent":2},"limit":null}}"#,
        // Boolean amount.
        #"{"spend":{"enabled":true,"used":{"amount_minor":true,"currency":"USD","exponent":2},"limit":null}}"#,
        // Non-positive cap.
        #"{"spend":{"enabled":true,"used":{"amount_minor":1,"currency":"USD","exponent":2},"limit":{"amount_minor":0,"currency":"USD","exponent":2}}}"#,
        // Present spend supersedes legacy, even when spend itself is unusable.
        #"{"spend":{"enabled":false},"extra_usage":{"is_enabled":true,"monthly_limit":100,"used_credits":5}}"#,
        // Legacy disabled, and enabled flag that is a number rather than a JSON boolean.
        #"{"extra_usage":{"is_enabled":false,"monthly_limit":100,"used_credits":5}}"#,
        #"{"extra_usage":{"is_enabled":1,"monthly_limit":100,"used_credits":5}}"#,
    ])
    func extraUsageRejectsDisabledForeignOrMalformedAmounts(_ json: String) throws {
        #expect(try extraUsage(json) == nil)
    }

    @Test func extraUsageAloneIsUsableData() throws {
        let data = Data(#"""
        {"five_hour":null,"seven_day":null,"spend":{"enabled":true,"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null}}
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data)
        #expect(snapshot.credits == "$0.00")
        #expect(snapshot.windows.filter(\.usageKnown).isEmpty)
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
