import Foundation
import Testing
@testable import OhMyLimitCore

struct LaunchAtLoginTests {
    @Test func propertyListOpensAppAtLogin() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Oh My Limit.app", isDirectory: true)

        let data = try LaunchAtLogin.propertyList(appURL: appURL)

        let propertyList = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(propertyList["Label"] as? String == LaunchAtLogin.label)
        #expect(propertyList["ProgramArguments"] as? [String] == ["/usr/bin/open", appURL.path])
        #expect(propertyList["RunAtLoad"] as? Bool == true)
    }
}
