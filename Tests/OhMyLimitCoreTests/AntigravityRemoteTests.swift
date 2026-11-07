import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityRemoteTests {
    static let credentials = AntigravityOAuthCredentials(accessToken: "fixture-access", refreshToken: "fixture-refresh",
        expiresAt: Date(timeIntervalSince1970: 0), accountID: "selected-account", email: "selected@example.invalid")
    static let summary = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-09-16T12:00:00Z","description":"fixture-reset"},{"bucketId":"3p-weekly","remainingFraction":0.5}]}],"email":"wrong@example.invalid"}"#

    static func fixture(summary: String, summaryStatus: Int = 200, models: String = "{}",
                        modelsStatus: Int = 200, quota: String = "{}", quotaStatus: Int = 200) throws -> AntigravityLoopbackFixture {
        try AntigravityLoopbackFixture { request in
            if request.hasPrefix("POST /v1internal:loadCodeAssist ") {
                return AntigravityLoopbackFixture.response(#"{"cloudaicompanionProject":{"id":"fixture-project"},"paidTier":{"name":"fixture-plan"}}"#,
                    headers: "Set-Cookie: fixture-cookie=secret; Path=/\r\n")
            }
            if request.hasPrefix("POST /v1internal:retrieveUserQuotaSummary ") {
                return AntigravityLoopbackFixture.response(summary, status: summaryStatus)
            }
            if request.hasPrefix("POST /v1internal:fetchAvailableModels ") {
                return AntigravityLoopbackFixture.response(models, status: modelsStatus)
            }
            if request.hasPrefix("POST /v1internal:retrieveUserQuota ") {
                return AntigravityLoopbackFixture.response(quota, status: quotaStatus)
            }
            return AntigravityLoopbackFixture.response("{}", status: 500)
        }
    }

    static func run(_ server: AntigravityLoopbackFixture,
                    check: (Result<CodexUsageSnapshot, any Error>, [String]) throws -> Void) async throws {
        let port = try await server.start()
        let result: Result<CodexUsageSnapshot, any Error>
        do { result = .success(try await AntigravityRemoteClient(loopbackPort: port).fetchUsage(credentials: credentials)) }
        catch { result = .failure(error) }
        let requests = await server.requests()
        await server.stop()
        try check(result, requests)
    }

    @Test func groupedSummaryKeepsSelectedIdentityAndPlan() async throws {
        try await Self.run(Self.fixture(summary: Self.summary)) { response, requests in
            let result = try response.get()
            #expect(result.identity == CodexIdentity(email: Self.credentials.email, planType: "fixture-plan", accountID: Self.credentials.accountID))
            #expect(result.source == .antigravityOAuth)
            #expect(result.windows[0].usedPercent == 25)
            #expect(result.windows[0].usageKnown)
            #expect(result.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z"))
            #expect(result.windows[0].resetDescription != nil)
            #expect(result.windows[3].usedPercent == 50)
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.contains("Authorization: Bearer fixture-access\r\n") })
            #expect(requests.allSatisfy { !$0.contains("fixture-refresh") && !$0.lowercased().contains("cookie:") })
        }
    }

    @Test func requestsIdentifyAntigravityInsteadOfUnsupportedGeminiClient() async throws {
        let server = try AntigravityLoopbackFixture { request in
            guard request.contains("\r\nUser-Agent: antigravity/hub/2.26.0 (aidev_client; os_type=darwin; arch=arm64; cl=1005016104)\r\n") else {
                return AntigravityLoopbackFixture.response(
                    #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#, status: 403
                )
            }
            if request.hasPrefix("POST /v1internal:loadCodeAssist ") {
                let body = request.components(separatedBy: "\r\n\r\n").last ?? ""
                let fields = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
                let metadata = fields?["metadata"] as? [String: String]
                guard metadata == ["ideType": "ANTIGRAVITY"] else {
                    return AntigravityLoopbackFixture.response("{}", status: 400)
                }
                return AntigravityLoopbackFixture.response(#"{"cloudaicompanionProject":"fixture-project"}"#)
            }
            return AntigravityLoopbackFixture.response(Self.summary)
        }

        try await Self.run(server) { result, requests in
            let snapshot = try result.get()
            #expect(snapshot.windows[0].usedPercent == 25)
            #expect(snapshot.identity.accountID == Self.credentials.accountID)
            #expect(requests.count == 2)
        }
    }

    @Test(arguments: [#"{"groups":[]}"#, #"{"summary":{"groups":[{"buckets":[{"bucketId":"future","remainingFraction":0}]}]}}"#])
    func emptySummaryDoesNotFallBack(_ body: String) async throws {
        try await Self.run(Self.fixture(summary: body)) { response, requests in
            let result = try response.get()
            #expect(result.windows.prefix(4).allSatisfy { !$0.usageKnown })
            // A bucket outside the fixed schema is kept, not silently dropped.
            #expect(result.windows.dropFirst(4).map(\.id) == (body.contains("future") ? ["future"] : []))
            #expect(result.windows.dropFirst(4).allSatisfy { $0.usageKnown && $0.usedPercent == 100 })
            #expect(result.identity.accountID == Self.credentials.accountID)
            #expect(requests.count == 2)
        }
    }

    @Test(arguments: [401, 403, 429, 503])
    func statusErrorsAreTyped(_ status: Int) async throws {
        try await Self.run(Self.fixture(summary: #"{"error":{"message":"private-server-detail"}}"#, summaryStatus: status)) { response, requests in
            let expected: AntigravityOAuthError = status == 401 ? .signInRequired : status == 403 ? .quotaUnavailable : .networkFailure
            #expect(throws: expected) { try response.get() }
            #expect(requests.count == 2)
        }
    }

    @Test func disconnectedTransportIsTransient() async throws {
        try await Self.run(AntigravityLoopbackFixture { _ in "" }) { response, _ in
            #expect(throws: AntigravityOAuthError.networkFailure) { try response.get() }
        }
    }

    @Test func modelFractionsKeepResetWithoutInventingWindows() async throws {
        let models = #"{"models":{"gemini-model":{"displayName":"Gemini","quotaInfo":{"remainingFraction":0.25,"resetTime":"2026-09-16T12:00:00Z"}},"claude-model":{"quotaInfo":{"remainingFraction":0.5}}}}"#
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404, models: models)) { response, requests in
            let result = try response.get()
            #expect(result.windows.count == 2)
            #expect(result.windows.allSatisfy { $0.usageKnown && $0.windowDurationMins == nil })
            let gemini = try #require(result.windows.first { $0.label == "Gemini" })
            #expect(gemini.usedPercent == 75)
            #expect(gemini.resetsAt != nil)
            #expect(requests.count == 3)
        }
    }

    @Test func modelResetWithoutFractionIsExhausted() async throws {
        let models = #"{"models":{"gemini":{"quotaInfo":{"resetTime":"2026-09-16T12:00:00Z"}},"claude":{"quotaInfo":{"remainingFraction":1,"resetTime":"2026-09-16T12:00:00Z"}}}}"#
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404, models: models)) { response, requests in
            let windows = try response.get().windows
            let gemini = try #require(windows.first { $0.id == "gemini" })
            #expect(gemini.usageKnown)
            #expect(gemini.usedPercent == 100)
            #expect(gemini.resetsAt != nil)
            // An exhausted member means availability is not all-full: no dedicated detail call.
            #expect(requests.count == 3)
        }
    }

    @Test(arguments: [#"{"buckets":[]}"#, #"{"buckets":[{"modelId":"gemini","remainingFraction":0.5}]}"#, #"{"buckets":[{"modelId":"gemini","remainingFraction":1}]}"#])
    func fullAvailabilityNeedsDedicatedMeasurement(_ quota: String) async throws {
        let models = #"{"models":{"gemini":{"quotaInfo":{"remainingFraction":1,"resetTime":"2026-09-16T12:00:00Z"}}}}"#
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404, models: models, quota: quota)) { response, requests in
            let result = try response.get()
            if quota.contains("0.5") { #expect(result.windows.first?.usedPercent == 50) }
            else if quota.contains("modelId") { #expect(result.windows.first?.usageKnown == true); #expect(result.windows.first?.usedPercent == 0) }
            else { #expect(result.windows.allSatisfy { !$0.usageKnown }) }
            #expect(requests.count == 4)
        }
    }

    @Test func fullAvailabilityDeniedIsNotUnusedQuota() async throws {
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404,
            models: #"{"models":{"gemini":{"quotaInfo":{"remainingFraction":1}}}}"#, quotaStatus: 403)) { response, requests in
            #expect(throws: AntigravityOAuthError.quotaUnavailable) { try response.get() }
            #expect(requests.count == 4)
        }
    }

    @Test(arguments: ["null", "true", "-0.1", "1.1", "\"0.5\""])
    func malformedFractionsStayUnknown(_ fraction: String) async throws {
        let models = "{\"models\":{\"gemini\":{\"quotaInfo\":{\"remainingFraction\":\(fraction),\"resetTime\":\"2026-09-16T12:00:00Z\"}}}}"
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404, models: models)) { response, _ in
            let result = try response.get()
            #expect(result.windows.count == 1)
            #expect(result.windows[0].usageKnown == false)
            #expect(result.windows[0].resetsAt != nil)
        }
    }

    @Test func redirectsCannotForwardBearer() async throws {
        let target = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response(Self.summary) }
        let targetPort = try await target.start()
        let origin = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response("{}", status: 307, headers: "Location: http://127.0.0.1:\(targetPort)/stolen\r\n")
        }
        do {
            try await Self.run(origin) { response, requests in
                #expect(throws: AntigravityOAuthError.invalidResponse) { try response.get() }
                #expect(requests.count == 1)
            }
            #expect(await target.requests().isEmpty)
        } catch { await target.stop(); throw error }
        await target.stop()
    }

    @Test(arguments: [false, true])
    func oversizedResponseIsRejected(_ chunked: Bool) async throws {
        try await Self.run(AntigravityLoopbackFixture { _ in
            let body = String(repeating: "x", count: 1_048_577)
            return chunked
                ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n100001\r\n\(body)\r\n0\r\n\r\n"
                : AntigravityLoopbackFixture.response(body)
        }) { response, _ in
            #expect(throws: AntigravityOAuthError.invalidResponse) { try response.get() }
        }
    }

    @Test func authenticationChallengeDoesNotUseOtherCredentials() async throws {
        try await Self.run(AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response("{}", status: 401, headers: "WWW-Authenticate: Basic realm=\"fixture\"\r\n")
        }) { response, requests in
            #expect(throws: AntigravityOAuthError.signInRequired) { try response.get() }
            #expect(requests.count == 1)
        }
    }

    @Test(arguments: ["{}", "[]", #"{"groups":null}"#, "not-json"])
    func malformedSummaryDoesNotFallBack(_ body: String) async throws {
        try await Self.run(Self.fixture(summary: body)) { response, requests in
            #expect(throws: AntigravityOAuthError.invalidResponse) { try response.get() }
            #expect(requests.count == 2)
        }
    }

    @Test func disabledAndMissingFractionsAreUnknown() async throws {
        let models = #"{"models":{"disabled":{"quotaInfo":{"remainingFraction":0,"disabled":true}},"missing":{},"known":{"quotaInfo":{"remainingFraction":0.5}}}}"#
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404, models: models)) { response, requests in
            let windows = try response.get().windows
            #expect(windows.filter(\.usageKnown).count == 1)
            #expect(windows.first { $0.label == "known" }?.usedPercent == 50)
            #expect(requests.count == 3)
        }
    }

    @Test func modelShapedSummaryAndDeniedCatalogUseDedicatedQuota() async throws {
        let models = #"{"models":{"gemini":{"quotaInfo":{"remainingFraction":0.25}}}}"#
        try await Self.run(Self.fixture(summary: models)) { response, requests in
            let result = try response.get()
            #expect(result.windows.first?.usedPercent == 75)
            #expect(requests.count == 2)
        }
        try await Self.run(Self.fixture(summary: "{}", summaryStatus: 404, modelsStatus: 403,
            quota: #"{"buckets":[{"modelId":"gemini","remainingFraction":0.5}]}"#)) { response, requests in
            let result = try response.get()
            #expect(result.windows.first?.usedPercent == 50)
            #expect(requests.count == 4)
        }
    }

    @Test func timeoutBoundsUnresponsiveServer() async throws {
        let server = try AntigravityRemoteStalledFixture()
        let port = try await server.start()
        do { _ = try await AntigravityRemoteClient(loopbackPort: port, timeout: 0.2).fetchUsage(credentials: Self.credentials); Issue.record("Expected timeout") }
        catch { #expect(error as? AntigravityOAuthError == .timedOut) }
        await server.stop()
    }

    @Test func unsupportedVerificationDoesNotRestartPipeline() async throws {
        let models = #"{"models":{"gemini":{"quotaInfo":{"remainingFraction":1}}}}"#
        try await Self.run(Self.fixture(summary: models, models: models, quotaStatus: 404)) { response, requests in
            #expect(throws: AntigravityOAuthError.quotaUnavailable) { try response.get() }
            #expect(requests.count == 3)
        }
    }

    @Test func cancellationPropagatesAfterRequestArrival() async throws {
        let server = try AntigravityRemoteStalledFixture()
        let port = try await server.start()
        // Stream subscription exists before the action; the client's deadline bounds missing arrival.
        let task = Task {
            defer { server.arrivals.continuation.finish() }
            return try await AntigravityRemoteClient(loopbackPort: port).fetchUsage(credentials: Self.credentials)
        }
        var iterator = server.arrivals.stream.makeAsyncIterator()
        let request = await iterator.next()
        #expect(request?.hasPrefix("POST /v1internal:loadCodeAssist ") == true)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        await server.stop()
    }

    static func runWithFallback(primary: AntigravityLoopbackFixture, fallback: AntigravityLoopbackFixture,
                                check: (Result<CodexUsageSnapshot, any Error>, [String], [String]) throws -> Void) async throws {
        let primaryPort = try await primary.start()
        let fallbackPort: Int
        do { fallbackPort = try await fallback.start() } catch { await primary.stop(); throw error }
        let result: Result<CodexUsageSnapshot, any Error>
        do {
            result = .success(try await AntigravityRemoteClient(loopbackPort: primaryPort, fallbackLoopbackPort: fallbackPort)
                .fetchUsage(credentials: credentials))
        } catch { result = .failure(error) }
        let primaryRequests = await primary.requests()
        let fallbackRequests = await fallback.requests()
        await primary.stop()
        await fallback.stop()
        try check(result, primaryRequests, fallbackRequests)
    }

    @Test(arguments: [408, 429, 500, 503])
    func transientQuotaHostFailureFallsThroughToNextHost(_ status: Int) async throws {
        try await Self.runWithFallback(primary: Self.fixture(summary: "{}", summaryStatus: status),
                                       fallback: Self.fixture(summary: Self.summary)) { response, primary, fallback in
            let snapshot = try response.get()
            #expect(snapshot.windows[0].usedPercent == 25)
            #expect(primary.count == 2)
            #expect(fallback.count == 1)
            #expect(fallback.first?.hasPrefix("POST /v1internal:retrieveUserQuotaSummary ") == true)
            #expect(fallback.filter { !$0.contains("Authorization: Bearer fixture-access\r\n") }.isEmpty)
        }
    }

    @Test(arguments: [401, 403, 404])
    func finalQuotaHostAnswersDoNotFallThrough(_ status: Int) async throws {
        try await Self.runWithFallback(primary: Self.fixture(summary: "{}", summaryStatus: status, modelsStatus: status, quotaStatus: status),
                                       fallback: Self.fixture(summary: Self.summary)) { response, _, fallback in
            let expected: AntigravityOAuthError = status == 401 ? .signInRequired : .quotaUnavailable
            #expect(throws: expected) { try response.get() }
            #expect(fallback.isEmpty)
        }
    }

    @Test func manifestVersionParsesFirstVersionLine() {
        #expect(AntigravityClientVersion.manifestVersion("versionCode: 9\nversion: 2.31.4\nfiles: []\n") == "2.31.4")
        #expect(AntigravityClientVersion.manifestVersion("  version : \"2.31.4\" # latest\r\n") == "2.31.4")
        #expect(AntigravityClientVersion.manifestVersion("version: '2.31.4'") == "2.31.4")
        #expect(AntigravityClientVersion.manifestVersion("version: 2.31.4-beta\nversion: 2.31.4") == nil)
        #expect(AntigravityClientVersion.manifestVersion("version: 2.31.4\r\nX-Injected: 1") == "2.31.4")
        #expect(AntigravityClientVersion.manifestVersion("path: app.zip\n") == nil)
    }

    @Test func manifestVersionIsDiscoveredOnceAndSentAsUserAgent() async throws {
        let manifest = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response("version: 2.31.4\npath: Antigravity.zip\n")
        }
        let manifestPort = try await manifest.start()
        let version = AntigravityClientVersion(manifestURL: URL(string: "http://127.0.0.1:\(manifestPort)/manifest/latest-arm64-mac.yml")!)
        let first = await version.current()
        let second = await version.current()
        let manifestRequests = await manifest.requests()
        await manifest.stop()
        #expect(first == "2.31.4")
        #expect(second == "2.31.4")
        #expect(manifestRequests.count == 1)
        #expect(manifestRequests.first?.hasPrefix("GET /manifest/latest-arm64-mac.yml ") == true)
        #expect(manifestRequests.allSatisfy { !$0.contains("fixture-access") })

        let server = try Self.fixture(summary: Self.summary)
        let port = try await server.start()
        let result: Result<CodexUsageSnapshot, any Error>
        do { result = .success(try await AntigravityRemoteClient(loopbackPort: port, version: version).fetchUsage(credentials: Self.credentials)) }
        catch { result = .failure(error) }
        let requests = await server.requests()
        await server.stop()
        _ = try result.get()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.contains("\r\nUser-Agent: antigravity/hub/2.31.4 (aidev_client; os_type=darwin; arch=arm64; cl=1005016104)\r\n")
        })
    }

    @Test(arguments: [#"version: latest"#, ""])
    func failedManifestLookupFallsBackWithoutRetrying(_ body: String) async throws {
        let manifest = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response(body, status: body.isEmpty ? 500 : 200)
        }
        let manifestPort = try await manifest.start()
        let version = AntigravityClientVersion(manifestURL: URL(string: "http://127.0.0.1:\(manifestPort)/manifest.yml")!)
        let first = await version.current()
        let second = await version.current()
        let manifestRequests = await manifest.requests()
        await manifest.stop()
        #expect(first == AntigravityClientVersion.fallbackVersion)
        #expect(second == AntigravityClientVersion.fallbackVersion)
        #expect(manifestRequests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledCallerStopsWaitingForStalledManifest() async throws {
        let manifest = try AntigravityRemoteStalledFixture()
        let port = try await manifest.start()
        var arrivals = manifest.arrivals.stream.makeAsyncIterator()
        let version = AntigravityClientVersion(manifestURL: URL(string: "http://127.0.0.1:\(port)/manifest.yml")!, timeout: 30)
        let started = Date()
        let waiting = Task { await version.current() }
        _ = await arrivals.next()
        waiting.cancel()
        let result = await waiting.value
        let elapsed = Date().timeIntervalSince(started)
        await manifest.stop()
        #expect(result == AntigravityClientVersion.fallbackVersion)
        #expect(elapsed < 5)
    }
}
