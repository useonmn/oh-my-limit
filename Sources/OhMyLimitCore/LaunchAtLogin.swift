import Foundation

public enum LaunchAtLogin {
    public static let label = "local.ohmylimit.app.login"

    public static func isEligible(appURL: URL, volumeIsReadOnly: Bool, arguments: [String]) -> Bool {
        appURL.pathExtension == "app"
            && !appURL.pathComponents.contains("AppTranslocation")
            && !appURL.path.hasPrefix("/Volumes/")
            && !volumeIsReadOnly
            && !arguments.contains(where: {
                ["--preview", "--capture", "--capture-scroll-bottom", "--probe-antigravity"].contains($0)
            })
    }
}
