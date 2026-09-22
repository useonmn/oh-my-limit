import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityClientTests {
    @Test func localPreferredAndFreshCLIIdentity() async throws {
        let fixture = try AntigravityFixture()
        defer { try! fixture.remove() }
        let local = CodexUsageSnapshot(identity: CodexIdentity(email: "local@example.invalid"), windows: [], source: .antigravityApp)
        let first = try await AntigravityClient(executableURL: fixture.executable, localFetch: { local }).fetchUsage()
        #expect(first == local)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launches").path))
        let second = try await AntigravityClient(executableURL: fixture.executable, localFetch: { throw AntigravityClientError.localUnavailable }).fetchUsage()
        #expect(second.identity == CodexIdentity())
        #expect(second.source == .antigravityCLI)
        #expect(second.windows[0].usedPercent == 25)
        let launches = try fixture.launches()
        #expect(launches.count == 2)
        #expect(launches[0]["args"] as? [String] == ["--version"])
        #expect(launches.allSatisfy { ($0["files"] as? [String]) == [] && ($0["permissions"] as? Int) == 0o700 })
        #expect(try fixture.reapedAndCleaned())
    }

    @Test func oldVersionNeverPrints() async throws {
        let fixture = try AntigravityFixture("old")
        defer { try! fixture.remove() }
        do {
            _ = try await AntigravityClient(executableURL: fixture.executable, localFetch: { throw AntigravityClientError.localUnavailable }).fetchUsage()
            Issue.record("Expected version rejection")
        } catch { #expect(error as? AntigravityClientError == .unsupportedVersion) }
        #expect(try fixture.launches().count == 1)
        #expect(try fixture.reapedAndCleaned())
    }

    @Test(arguments: ["stdout", "stderr", "error"])
    func commandBoundsAndSanitizedErrors(_ scenario: String) async throws {
        let fixture = try AntigravityFixture(scenario)
        defer { try! fixture.remove() }
        do {
            _ = try await AntigravityCommand.run(executable: fixture.executable, arguments: Self.printArguments, timeout: 5)
            Issue.record("Expected command rejection")
        } catch {
            #expect(error as? AntigravityClientError == (scenario == "error" ? .processFailed : .outputLimitExceeded))
        }
        #expect(try fixture.reapedAndCleaned())
    }

    @Test func cancellationWaitsForReapingAndDirectoryRemoval() async throws {
        let fixture = try AntigravityFixture("cancel")
        defer { try! fixture.remove() }
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.continuation.finish() }
            return try await AntigravityCommand.run(executable: fixture.executable, arguments: Self.printArguments, timeout: 5) { _ in
                ready.continuation.yield(())
                ready.continuation.finish()
            }
        }
        var received = false
        // The command's deadline bounds this exact stdout readiness event, including startup failure.
        for await _ in ready.stream { received = true }
        #expect(received)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(try fixture.reapedAndCleaned())
    }

    @Test func timeoutReapsTermResistantChild() async throws {
        let fixture = try AntigravityFixture("timeout")
        defer { try! fixture.remove() }
        do {
            _ = try await AntigravityCommand.run(executable: fixture.executable, arguments: Self.printArguments, timeout: 2)
            Issue.record("Expected timeout")
        } catch { #expect(error as? AntigravityClientError == .timedOut) }
        #expect(try fixture.reapedAndCleaned())
    }

    @Test func cancellationDoesNotFallBackToCLI() async throws {
        let fixture = try AntigravityFixture()
        defer { try! fixture.remove() }
        do {
            _ = try await AntigravityClient(executableURL: fixture.executable, localFetch: { throw CancellationError() }).fetchUsage()
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launches").path))
    }

    static let printArguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "90s"]
}
