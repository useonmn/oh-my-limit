import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct CodexProtocolTests {
    @Test func unavailableQuotaSurvivesCacheRoundTripWithoutBecomingKnownZero() throws {
        let data = Data(#"""
        {"id":"antigravity.gemini-weekly","label":"Gemini","usedPercent":0,"usageKnown":false,"windowDurationMins":10080,"resetDescription":"Weekly quota"}
        """#.utf8)
        let window = try JSONDecoder().decode(CodexQuotaWindow.self, from: data)

        let encoded = try JSONEncoder().encode(window)

        let value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(value["usageKnown"] as? Bool == false)
    }

    @Test func partialAndMultipleLinesPreserveUTF8() throws {
        var framer = CodexLineFramer()
        let first = Data(#"{"method":"알림"}"#.utf8)
        let second = Data(#"{"id":1,"result":{}}"#.utf8)
        var completed: [Data] = []
        for byte in first { completed += try framer.append(Data([byte])) }
        #expect(completed.isEmpty)
        #expect(framer.hasPartialLine)
        completed += try framer.append(Data([0x0A, 0x0A]) + second + Data([0x0D, 0x0A]))
        #expect(completed == [first, second + Data([0x0D])])
        #expect(!framer.hasPartialLine)
    }

    @Test func framingBoundsBothLinesAndTotalOutput() throws {
        var longLine = CodexLineFramer()
        #expect(throws: CodexClientError.outputLimitExceeded) {
            try longLine.append(Data(repeating: 120, count: 1024 * 1024 + 1))
        }
        var total = CodexLineFramer()
        let chunk = Data(repeating: 0x0A, count: 8192)
        for _ in 0..<1024 { _ = try total.append(chunk) }
        #expect(throws: CodexClientError.outputLimitExceeded) { try total.append(Data([0x0A])) }
    }

    @Test func authoritativeMapIgnoresEvenInvalidLegacy() throws {
        let data = Data(#"{"rateLimits":"obsolete","rateLimitsByLimitId":{},"account_id":"returned"}"#.utf8)
        let usage = try CodexResponseParser.usage(from: data, identity: CodexIdentity(accountID: "old"))
        #expect(usage.windows.isEmpty)
        #expect(usage.identity.accountID == "returned")
    }

    @Test func nullableMapFallsBackAndMissingWindowsRemainAbsent() throws {
        let data = Data(#"{"rateLimits":{"primary":null},"rateLimitsByLimitId":null}"#.utf8)
        let usage = try CodexResponseParser.usage(from: data, identity: CodexIdentity())
        #expect(usage.windows.isEmpty)
        #expect(usage.credits == nil)
        #expect(usage.ordinaryUsageAllowed == nil)
    }

    @Test(arguments: ["-1", "1e999", "true", "null", #""NaN""#])
    func invalidWirePercentagesAreRejected(_ value: String) {
        let data = Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(value)}}}".utf8)
        #expect(throws: CodexClientError.malformedProtocol) {
            try CodexResponseParser.usage(from: data, identity: CodexIdentity())
        }
    }

    @Test(arguments: ["NaN", "Infinity", "-Infinity"])
    func decodedModelsRejectNonfinitePercentages(_ value: String) {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = Data("{\"id\":\"x\",\"label\":\"x\",\"usedPercent\":\"\(value)\"}".utf8)
        #expect(throws: (any Error).self) { try decoder.decode(CodexQuotaWindow.self, from: data) }
    }

    @Test func unknownBucketsKeepNamesAndStableDistinctIDs() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"other":{"limitName":"Server Name","primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":101,"windowDurationMins":10080}}}}"#.utf8)
        let usage = try CodexResponseParser.usage(from: data, identity: CodexIdentity())
        #expect(usage.windows.map(\.label) == ["Server Name", "Server Name"])
        #expect(usage.windows.map(\.id) == ["other.primary", "other.secondary"])
        #expect(usage.windows.map(\.usedPercent) == [0, 101])
    }

    @Test func accountIDIsStructuredAndNonChatGPTModesAreRejected() throws {
        let identity = try CodexResponseParser.identity(from: Data(#"{"account":{"type":"chatgpt","email":null,"account_id":"id"}}"#.utf8))
        #expect(identity == CodexIdentity(accountID: "id"))
        for type in ["apiKey", "amazonBedrock", "chatgptAuthTokens", "unknown"] {
            #expect(throws: CodexClientError.notLoggedIn) {
                try CodexResponseParser.identity(from: Data("{\"account\":{\"type\":\"\(type)\"}}".utf8))
            }
        }
    }

    @Test(arguments: [
        "http://auth.openai.com/oauth/authorize", "https://auth.openai.com.evil.invalid/oauth/authorize",
        "https://evil.invalid/?next=https://auth.openai.com", "https://user:secret@auth.openai.com/oauth/authorize",
        "https://auth.openai.com:444/oauth/authorize", "file:///oauth/authorize", "javascript:alert(1)",
        "https://auth.openai.com/oauth/authorize#secret", "https://auth.openai.com/not-a-login"
    ])
    func rejectsUnofficialLoginURLs(_ text: String) {
        #expect(CodexRPCTransport.officialLoginURL(text) == nil)
    }

    @Test(arguments: ["https://auth.openai.com/oauth/authorize?state=fixture", "https://chatgpt.com/auth/login?state=fixture"])
    func acceptsOfficialHTTPSLoginURLs(_ text: String) {
        #expect(CodexRPCTransport.officialLoginURL(text)?.absoluteString == text)
    }
}
