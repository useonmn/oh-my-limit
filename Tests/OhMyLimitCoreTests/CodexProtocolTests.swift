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

    @Test(arguments: ["NaN", "Infinity", "-Infinity"])
    func decodedModelsRejectNonfinitePercentages(_ value: String) {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = Data("{\"id\":\"x\",\"label\":\"x\",\"usedPercent\":\"\(value)\"}".utf8)
        #expect(throws: (any Error).self) { try decoder.decode(CodexQuotaWindow.self, from: data) }
    }

    @Test func durationLabelUsesExactKoreanUnits() {
        #expect([300, 10_080, 2_880, 180, 90].map(CodexQuotaWindow.durationLabel(minutes:))
                == ["5시간", "주간", "2일", "3시간", "90분"])
    }
}
