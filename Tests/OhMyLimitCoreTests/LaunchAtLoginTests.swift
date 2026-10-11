import Foundation
import Testing
@testable import OhMyLimitCore

struct LaunchAtLoginTests {
    @Test(arguments: [
        ("/Applications/Oh My Limit.app", false, [String](), true),
        ("/Volumes/External/OhMyLimit.app", false, [], false),
        ("/Volumes/Installer/OhMyLimit.app", true, [], false),
        ("/private/var/folders/AppTranslocation/random/OhMyLimit.app", false, [], false),
        ("/project/.build/debug", false, [], false),
        ("/Applications/OhMyLimit.app", false, ["--preview", "normal"], false),
        ("/Applications/OhMyLimit.app", false, ["--capture", "/tmp/out.png"], false),
        ("/Applications/OhMyLimit.app", false, ["--probe-antigravity"], false),
    ])
    func eligibility(path: String, readOnly: Bool, arguments: [String], expected: Bool) {
        #expect(LaunchAtLogin.isEligible(
            appURL: URL(fileURLWithPath: path), volumeIsReadOnly: readOnly, arguments: arguments
        ) == expected)
    }
}
