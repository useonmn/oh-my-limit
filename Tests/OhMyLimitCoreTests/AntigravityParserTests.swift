import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityParserTests {
    @Test func summaryKeepsFourExactBucketsAndUnknowns() throws {
        let data = Data(#"{"response":{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1},{"bucketId":"gemini-weekly","remainingFraction":0.25,"resetTime":"2026-09-16T00:00:00Z"},{"bucketId":"3p-5h"},{"bucketId":"gemini-image-5h","remainingFraction":0}]}]}}"#.utf8)
        let result = try AntigravityParser.summary(data, source: .antigravityApp)
        #expect(result.windows.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        #expect(result.windows.map(\.usageKnown) == [true, true, false, false])
        #expect(result.windows[0].usedPercent == 0)
        #expect(result.windows[1].usedPercent == 75)
        #expect(result.windows[1].resetsAt != nil)
        #expect(result.identity == CodexIdentity())
    }

    @Test func actualCLIReportSnakeCaseAndOneof() throws {
        let data = Data(#"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[{"bucket_id":"gemini-5h","remaining":{"case":"remainingFraction","value":0.4},"description":"Resets tomorrow"},{"bucket_id":"3p-weekly","remaining_fraction":0},{"bucket_id":"3p-5h","disabled":true,"remaining_fraction":1}]}]}}}"#.utf8)
        let result = try AntigravityParser.cli(data)
        #expect(result.source == .antigravityCLI)
        #expect(result.identity == CodexIdentity())
        #expect(result.windows[0].usedPercent == 60)
        #expect(result.windows[0].resetDescription == "Resets tomorrow")
        #expect(result.windows[2].usageKnown == false)
        #expect(result.windows[3].usedPercent == 100)
        #expect(result.windows[3].usageKnown)
    }

    @Test func emptySummaryIsAuthoritative() throws {
        let result = try AntigravityParser.summary(Data(#"{"groups":[]}"#.utf8), source: .antigravityApp)
        #expect(result.windows.count == 4)
        #expect(result.windows.allSatisfy { !$0.usageKnown })
    }

    @Test func legacyPoolsWorstKnownUsageButNeverInventsWeekly() throws {
        let data = Data(#"{"userStatus":{"email":"current@example.invalid","userTier":{"name":"Google AI Pro"},"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini 3 Pro","modelOrAlias":{"model":"gemini-pro"},"quotaInfo":{"remainingFraction":0.8}},{"label":"Gemini Flash","modelOrAlias":{"model":"gemini-flash"},"quotaInfo":{"remainingFraction":0.2}},{"label":"Claude","modelOrAlias":{"model":"claude"}}]}}}"#.utf8)
        let result = try AntigravityParser.legacy(data, source: .antigravityIDE)
        #expect(result.identity.email == "current@example.invalid")
        #expect(result.identity.planType == "Google AI Pro")
        #expect(result.windows[0].usedPercent == 80)
        #expect(result.windows.map(\.usageKnown) == [true, false, false, false])
    }

    @Test func malformedBucketsDoNotEraseValidBucketsOrBecomeZero() throws {
        let data = Data(#"{"groups":[{"buckets":[false,{"bucketId":"gemini-5h","remainingFraction":true},{"bucketId":"gemini-weekly","remainingFraction":-1},{"bucketId":"3p-5h","remainingFraction":2},{"bucketId":"3p-weekly","remainingFraction":0.5}]}]}"#.utf8)
        let result = try AntigravityParser.summary(data, source: .antigravityApp)
        #expect(result.windows.map(\.usageKnown) == [false, false, false, true])
        #expect(result.windows[3].usedPercent == 50)
    }

    @Test func missingLegacyPoolMemberMakesPoolUnknown() throws {
        let data = Data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini Pro","quotaInfo":{"remainingFraction":0.5}},{"label":"Gemini Flash"}]}}}"#.utf8)
        let result = try AntigravityParser.legacy(data, source: .antigravityApp)
        #expect(result.windows.allSatisfy { !$0.usageKnown })
    }

    @Test(arguments: [#"{}"#, #"{"status":"ERROR","command":{"name":"usage","data":{"groups":[]}}}"#, #"{"status":"SUCCESS","command":{"name":"chat","data":{"groups":[]}}}"#])
    func rejectsNonUsageReports(_ json: String) {
        #expect(throws: AntigravityClientError.malformedResponse) { try AntigravityParser.cli(Data(json.utf8)) }
    }
}
