import Foundation

public enum LaunchAtLogin {
    public static let label = "local.ohmylimit.app.login"

    public static func propertyList(appURL: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", appURL.path],
                "RunAtLoad": true,
            ],
            format: .xml,
            options: 0
        )
    }
}
