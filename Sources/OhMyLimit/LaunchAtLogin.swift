import Foundation
import OhMyLimitCore
import ServiceManagement
import SwiftUI

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?
    private let firstRunKey = "mainAppLoginInitialized"

    var isAvailable: Bool {
        let url = Bundle.main.bundleURL
        guard let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
              let readOnly = values.volumeIsReadOnly else { return false }
        return LaunchAtLogin.isEligible(
            appURL: url, volumeIsReadOnly: readOnly, arguments: CommandLine.arguments
        )
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func prepareForNormalLaunch() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAtLogin.label).plist")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            errorMessage = "이전 로그인 항목을 삭제하지 못했습니다: \(error.localizedDescription)"
        }
        guard isAvailable, !UserDefaults.standard.bool(forKey: firstRunKey) else { return }
        // Only the first eligible normal launch opts in; later launches honor system changes.
        UserDefaults.standard.set(true, forKey: firstRunKey)
        if status == .notRegistered { setEnabled(true) }
    }

    func refreshStatus() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = "로그인 시 실행 설정을 변경하지 못했습니다: \(error.localizedDescription)"
        }
        refreshStatus()
    }
}
