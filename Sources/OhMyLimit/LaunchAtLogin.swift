import Foundation
import OhMyLimitCore

@MainActor
func enableLaunchAtLogin() {
    do {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let file = directory.appendingPathComponent("\(LaunchAtLogin.label).plist")
        let data = try LaunchAtLogin.propertyList(appURL: Bundle.main.bundleURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? Data(contentsOf: file)) != data else { return }
        try data.write(to: file, options: .atomic)
    } catch {
        let message = "LaunchAgent installation failed: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
