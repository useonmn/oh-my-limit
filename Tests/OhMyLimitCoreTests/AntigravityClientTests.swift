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

    @Test(.timeLimit(.minutes(1)))
    func cancellationSignalsDescendantsBeforeReapingTheirLeader() async throws {
        let fixture = try AntigravityFixture("tree")
        defer { try! fixture.remove() }
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.continuation.finish() }
            return try await AntigravityCommand.run(
                executable: fixture.executable, arguments: Self.printArguments, timeout: 5
            ) { _ in
                ready.continuation.yield(())
                ready.continuation.finish()
            }
        }
        defer { task.cancel() }
        var events = ready.stream.makeAsyncIterator()
        _ = try #require(await events.next())
        let childText = try String(contentsOf: fixture.directory.appendingPathComponent("child"), encoding: .utf8)
        let child = try #require(Int32(childText))
        let leader = try #require(try fixture.launches().first?["pid"] as? Int)
        #expect(getpgid(child) == pid_t(leader))
        #expect(getpgid(pid_t(leader)) == pid_t(leader))
        let childExit = ChildExitEvent(pid: child)
        var registration = childExit.registered.makeAsyncIterator()
        _ = try #require(await registration.next())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Subscribe before cancelling; no assumptions about init's reap timing.
        var exits = childExit.events.makeAsyncIterator()
        #expect(await exits.next() == true)
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

private final class ChildExitEvent: @unchecked Sendable {
    let events: AsyncStream<Bool>
    let registered: AsyncStream<Void>
    private let signal: AsyncStream<Bool>.Continuation
    private let source: DispatchSourceProcess
    private let timeout: DispatchSourceTimer

    init(pid: pid_t) {
        (events, signal) = AsyncStream.makeStream()
        let readiness = AsyncStream<Void>.makeStream()
        registered = readiness.stream
        let queue = DispatchQueue(label: "ChildExitEvent")
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        timeout = DispatchSource.makeTimerSource(queue: queue)
        source.setRegistrationHandler {
            readiness.continuation.yield(())
            readiness.continuation.finish()
        }
        source.setEventHandler { [self] in finish(true) }
        timeout.setEventHandler { [self] in finish(false) }
        timeout.schedule(deadline: .now() + 5)
        source.resume()
        timeout.resume()
    }

    private func finish(_ exited: Bool) {
        source.setEventHandler {}
        timeout.setEventHandler {}
        source.cancel()
        timeout.cancel()
        signal.yield(exited)
        signal.finish()
    }
}
