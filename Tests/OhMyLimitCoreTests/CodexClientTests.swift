import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct CodexClientTests {
    @Test(arguments: ["usage", "usageExit"])
    func multiBucketUsageAndLaunchContract(_ scenario: String) async throws {
        let fixture = try CodexFixture(scenario)
        defer { try! fixture.remove() }
        let snapshot = try await CodexClient(executableURL: fixture.executable).fetchUsage(home: fixture.home)
        #expect(snapshot.identity == CodexIdentity(email: "fixture@example.invalid", planType: "plus", accountID: "fixture-account"))
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].usedPercent == 125.5)
        #expect(snapshot.windows[0].windowDurationMins == 300)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.windows[1].label == "Server Bucket")
        #expect(snapshot.windows[1].resetsAt == nil)
        #expect(snapshot.credits == "12.50")
        #expect(snapshot.ordinaryUsageAllowed == false)
        #expect(try fixture.assertReaped())
        let requests = try fixture.requests()
        #expect(requests.compactMap { $0["method"] as? String } == ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        let launch = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.home.appendingPathComponent("CodexLaunch"))) as! [String: Any]
        let args = launch["args"] as! [String]
        #expect(args.contains("app-server"))
        #expect(args.contains("sandbox_mode=\"read-only\""))
        #expect(args.contains("approval_policy=\"never\""))
        #expect(launch["home"] as? String == fixture.home.path)
        #expect(launch["path"] as? String == ProcessInfo.processInfo.environment["PATH"])
    }

    @Test func legacyAndNullableWindows() async throws {
        let fixture = try CodexFixture("legacy")
        defer { try! fixture.remove() }
        let snapshot = try await CodexClient(executableURL: fixture.executable).fetchUsage(home: fixture.home)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.ordinaryUsageAllowed == nil)
        #expect(try fixture.assertReaped())
    }

    @Test(arguments: ["apiKey", "loggedOut"])
    func nonChatGPTIsNotLoggedIn(_ scenario: String) async throws {
        try await checkError(scenario, expected: .notLoggedIn)
    }

    @Test(arguments: ["negative", "malformed", "partialEOF"])
    func rejectsMalformedProtocol(_ scenario: String) async throws {
        try await checkError(scenario, expected: .malformedProtocol)
    }

    @Test func boundedOutput() async throws {
        try await checkError("oversize", expected: .outputLimitExceeded)
    }

    @Test func boundedStderr() async throws {
        try await checkError("stderr", expected: .outputLimitExceeded)
    }

    @Test func serverErrorsDoNotExposeBackendText() async throws {
        try await checkError("serverError", expected: .serverError(code: -32000))
    }

    @Test func unexpectedExit() async throws {
        try await checkError("eof", expected: .processExited)
    }

    @Test func timeoutReapsTermResistantProcess() async throws {
        let fixture = try CodexFixture("cancel")
        defer { try! fixture.remove() }
        let client = CodexClient(executableURL: fixture.executable, timeout: 20, loginTimeout: 0.05)
        do {
            _ = try await client.login(home: fixture.home) { _ in }
            Issue.record("Expected browser login deadline")
        } catch { #expect(error as? CodexClientError == .timedOut) }
        #expect(try fixture.assertReaped())
    }

    @Test(arguments: ["login", "loginEarly"])
    func loginMatchesCompletionEvenBeforeStartResponse(_ scenario: String) async throws {
        let fixture = try CodexFixture(scenario)
        defer { try! fixture.remove() }
        let urls = AsyncStream<URL>.makeStream()
        let identity = try await CodexClient(executableURL: fixture.executable).login(home: fixture.home) {
            urls.continuation.yield($0)
        }
        urls.continuation.finish()
        var received: [URL] = []
        for await url in urls.stream { received.append(url) }
        #expect(received.count == 1)
        #expect(received.first?.host == "auth.openai.com")
        #expect(identity.email == "fixture@example.invalid")
        #expect(try fixture.assertReaped())
    }

    @Test(arguments: ["loginFailure", "unsafeURL"])
    func rejectsFailedLoginOrUnsafeURL(_ scenario: String) async throws {
        let fixture = try CodexFixture(scenario)
        defer { try! fixture.remove() }
        do {
            _ = try await CodexClient(executableURL: fixture.executable).login(home: fixture.home) { _ in }
            Issue.record("Expected login rejection")
        } catch {
            #expect(error as? CodexClientError == (scenario == "unsafeURL" ? .invalidLoginURL : .loginFailed))
        }
        #expect(try fixture.assertReaped())
    }

    @Test func cancellationAfterURLReapsTermResistantProcess() async throws {
        let fixture = try CodexFixture("cancel")
        defer { try! fixture.remove() }
        let urls = AsyncStream<URL>.makeStream()
        let task = Task {
            try await CodexClient(executableURL: fixture.executable).login(home: fixture.home) {
                urls.continuation.yield($0)
                urls.continuation.finish()
            }
        }
        // The transport deadline bounds this event wait; finish the stream on failure too.
        let completion = Task {
            defer { urls.continuation.finish() }
            return await task.result
        }
        var received = false
        for await _ in urls.stream { received = true }
        #expect(received)
        task.cancel()
        let outcome = await completion.value
        if case .failure(let error) = outcome { #expect(error is CancellationError) }
        else { Issue.record("Cancellation must propagate") }
        #expect(try fixture.assertReaped())
    }

    @Test func alreadyCancelledTaskDoesNotLaunch() async throws {
        let fixture = try CodexFixture()
        defer { try! fixture.remove() }
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in ready.stream { }
            return try await CodexClient(executableURL: fixture.executable).fetchUsage(home: fixture.home)
        }
        task.cancel()
        ready.continuation.finish()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation before launch")
        } catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("CodexPID").path))
    }

    @Test func missingExecutableIsSanitized() async {
        do {
            _ = try await CodexClient(executableURL: URL(fileURLWithPath: "/CodexNonexistent-secret")).fetchUsage(home: URL(fileURLWithPath: "/tmp"))
            Issue.record("Expected launch failure")
        } catch { #expect(error as? CodexClientError == .launchFailed) }
    }

    @Test func modelsRoundTripAndRejectInvalidDecodedPercentages() throws {
        let window = CodexQuotaWindow(id: "codex.primary", label: "fixture", usedPercent: 150, windowDurationMins: nil, resetsAt: nil)
        let snapshot = CodexUsageSnapshot(identity: CodexIdentity(), windows: [window], fetchedAt: Date(timeIntervalSince1970: 1))
        #expect(try JSONDecoder().decode(CodexUsageSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        let invalid = Data(#"{"id":"x","label":"x","usedPercent":-1}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CodexQuotaWindow.self, from: invalid) }
    }

    private func checkError(_ scenario: String, expected: CodexClientError, timeout: TimeInterval = 20) async throws {
        let fixture = try CodexFixture(scenario)
        defer { try! fixture.remove() }
        do {
            _ = try await CodexClient(executableURL: fixture.executable, timeout: timeout).fetchUsage(home: fixture.home)
            Issue.record("Expected RPC failure")
        } catch { #expect(error as? CodexClientError == expected) }
        #expect(try fixture.assertReaped())
    }
}
