import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityLocalTests {
    @Test func nativeAppThenCLIThenIDEIsTheSourcePriority() {
        #expect(AntigravityLocal.rank(.antigravityApp) < AntigravityLocal.rank(.antigravityCLI))
        #expect(AntigravityLocal.rank(.antigravityCLI) < AntigravityLocal.rank(.antigravityIDE))
        #expect(AntigravityLocal.classify(
            path: "/Applications/Gemini.app/Contents/Resources/language_server", officialCLI: nil
        ) == nil)
    }

    @Test func probePrefixCoversDistinctCandidatesBeforeExtraPorts() {
        let groups = [[1, 2, 3, 4], [11, 12], [21]].enumerated().map { index, ports in
            ports.map { AntigravityEndpoint(port: $0, csrf: "c\(index)", source: index == 0 ? .antigravityApp : .antigravityIDE) }
        }
        let endpoints = AntigravityLocal.interleave(groups)
        #expect(endpoints.map(\.port) == [1, 11, 21, 2, 12, 3, 4])
        #expect(endpoints.prefix(3).map(\.csrf) == ["c0", "c1", "c2"])
        #expect(AntigravityLocal.interleave([]).isEmpty)
    }

    @Test(arguments: [true, false])
    func summaryQuotaSurvivesOptionalIdentityLookup(_ identityAvailable: Bool) async throws {
        let server = try AntigravityLoopbackFixture { request in
            if request.contains("/RetrieveUserQuotaSummary ") {
                return AntigravityLoopbackFixture.response(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5}]}]}"#)
            }
            if !identityAvailable { return AntigravityLoopbackFixture.response("{}", status: 503) }
            return AntigravityLoopbackFixture.response(#"{"userStatus":{"email":"current@example.invalid","userTier":{"name":"Google AI Pro"},"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini","quotaInfo":{"remainingFraction":0}}]}}}"#)
        }
        let port = try await server.start()
        do {
            let result = try await AntigravityLocal.fetch(
                endpoint: AntigravityEndpoint(port: port, csrf: "fixture-only", source: .antigravityApp)
            )
            #expect(result.windows[0].usedPercent == 50)
            #expect(result.windows[0].usageKnown)
            #expect(result.identity.email == (identityAvailable ? "current@example.invalid" : nil))
            #expect(result.identity.planType == (identityAvailable ? "Google AI Pro" : nil))
            #expect(await server.requests().count == 2)
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test func emptySummaryPreventsLegacyAndCLIFallback() async throws {
        let server = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response(#"{"response":{"groups":[]}}"#) }
        let port = try await server.start()
        do {
            let result = try await AntigravityClient(executableURL: URL(fileURLWithPath: "/must-not-launch"), localFetch: {
                try await AntigravityLocal.fetch(endpoint: AntigravityEndpoint(port: port, csrf: "fixture-only", source: .antigravityApp))
            }).fetchUsage()
            #expect(result.windows.count == 4)
            #expect(result.windows.allSatisfy { !$0.usageKnown })
            let requests = await server.requests()
            #expect(requests.count == 1)
            #expect(requests[0].contains("/RetrieveUserQuotaSummary "))
            #expect(requests[0].lowercased().contains("x-codeium-csrf-token: fixture-only"))
            #expect(result.identity == CodexIdentity())
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test(arguments: [404, 405, 501])
    func unavailableSummaryUsesLegacy(_ status: Int) async throws {
        let server = try AntigravityLoopbackFixture { request in
            if request.contains("/RetrieveUserQuotaSummary ") { return AntigravityLoopbackFixture.response("{}", status: status) }
            return AntigravityLoopbackFixture.response(#"{"userStatus":{"email":"response@example.invalid","cascadeModelConfigData":{"clientModelConfigs":[{"label":"Claude","quotaInfo":{"remainingFraction":0}}]}}}"#)
        }
        let port = try await server.start()
        do {
            let result = try await AntigravityLocal.fetch(endpoint: AntigravityEndpoint(port: port, csrf: "", source: .antigravityIDE))
            #expect(result.identity.email == "response@example.invalid")
            #expect(result.windows[2].usedPercent == 100)
            #expect(result.windows[2].usageKnown)
            #expect(!result.windows[3].usageKnown)
            let requests = await server.requests()
            #expect(requests.count == 2)
            #expect(requests[1].contains("/GetUserStatus "))
            #expect(!requests[1].lowercased().contains("x-codeium-csrf-token"))
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    @Test func redirectsNeverForwardCSRFToAnotherServer() async throws {
        let target = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response(#"{"groups":[]}"#) }
        let targetPort = try await target.start()
        let server = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response("", status: 302, headers: "Location: http://127.0.0.1:\(targetPort)/stolen\r\n")
        }
        let port = try await server.start()
        do {
            _ = try await AntigravityLocal.fetch(endpoint: AntigravityEndpoint(port: port, csrf: "fixture-only", source: .antigravityApp))
            Issue.record("Expected redirect rejection")
        } catch { #expect(error as? AntigravityClientError == .localUnavailable) }
        #expect(await target.requests().isEmpty)
        #expect(await server.requests().count == 1)
        await server.stop()
        await target.stop()
    }

    @Test func oversizedHTTPIsRejected() async throws {
        let server = try AntigravityLoopbackFixture { _ in AntigravityLoopbackFixture.response(String(repeating: "x", count: 1_048_577)) }
        let port = try await server.start()
        do {
            _ = try await AntigravityLocal.fetch(endpoint: AntigravityEndpoint(port: port, csrf: "", source: .antigravityApp))
            Issue.record("Expected size rejection")
        } catch { #expect(error as? AntigravityClientError == .outputLimitExceeded) }
        await server.stop()
    }

    @Test func processClassificationUsesExecutableNotSpoofedArguments() {
        #expect(AntigravityLocal.classify(path: "/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm", officialCLI: nil) == .antigravityApp)
        #expect(AntigravityLocal.classify(path: "/Applications/Antigravity IDE.app/Contents/Resources/language_server_macos_arm", officialCLI: nil) == .antigravityIDE)
        #expect(AntigravityLocal.classify(path: "/tmp/notantigravity.app/Contents/language_server", officialCLI: nil) == nil)
        #expect(AntigravityLocal.classify(path: "/tmp/agy", officialCLI: "/opt/homebrew/bin/agy") == nil)
        #expect(AntigravityLocal.classify(path: "/opt/homebrew/bin/agy", officialCLI: "/opt/homebrew/bin/agy") == .antigravityCLI)
        #expect(AntigravityLocal.classify(path: "/bin/echo --app_data_dir antigravity --csrf_token fake", officialCLI: nil) == nil)
        #expect(AntigravityLocal.ports(Data("p42\nn127.0.0.1:1234\nn*:4567\nn[::1]:1234\nn127.0.0.1:99999\n".utf8)) == [1234, 4567])
    }

    @Test(arguments: ["localhost", "127.0.0.1.evil.invalid", "example.invalid", "0.0.0.0", "127.1"])
    func TLSExceptionsNeverTrustNamesOrNonLoopback(_ host: String) {
        #expect(!AntigravityLoopbackSession.isLoopback(host))
    }

    @Test(arguments: ["1.1.10", "1.1.11-beta", "agy 1.2.0", "1.1.11\nunsafe", "999999999999999999999999999.0.0"])
    func conservativeVersionGate(_ version: String) { #expect(!AntigravityClient.supportsUsage(version)) }
}
