import AppKit
import OhMyLimitCore
import SwiftUI

extension ApplicationDelegate {
    func showPreview(_ scenario: String) {
        NSApp.setActivationPolicy(.regular)
        if let appearance = argument("--appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let content: AnyView
        if scenario == "settings" || scenario == "settings-connected" || scenario == "settings-claude" {
            let store = AccountStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            previewDirectory = store.directory
            if scenario == "settings-claude" {
                do {
                    try store.save([
                        AccountProfile(name: "Claude", homePath: store.directory.path, isManaged: false,
                                       provider: .claude, authentication: .oauth,
                                       oauthIdentity: CodexIdentity(email: "claude@example.com", accountID: "preview"))
                    ])
                } catch {
                    FileHandle.standardError.write(Data("Preview setup failed: \(error)\n".utf8))
                    try? FileManager.default.removeItem(at: store.directory)
                    exit(1)
                }
            }
            if scenario == "settings-connected" {
                do {
                    try store.save([
                        AccountProfile(name: "개인", homePath: store.directory.path, isManaged: false,
                                       authentication: .oauth, oauthIdentity: CodexIdentity(email: "personal@example.com")),
                        AccountProfile(name: "업무", homePath: store.directory.path, isManaged: false,
                                       authentication: .oauth, oauthIdentity: CodexIdentity(email: "work@example.com")),
                        AccountProfile(name: "Claude", homePath: store.directory.path, isManaged: false,
                                       provider: .claude, authentication: .oauth,
                                       oauthIdentity: CodexIdentity(email: "claude@example.com")),
                        AccountProfile(name: "Antigravity", homePath: store.directory.path, isManaged: false,
                                       provider: .antigravity, authentication: .oauth,
                                       oauthIdentity: CodexIdentity(email: "team@example.com"))
                    ])
                } catch {
                    FileHandle.standardError.write(Data("Preview setup failed: \(error)\n".utf8))
                    try? FileManager.default.removeItem(at: store.directory)
                    exit(1)
                }
            }
            let model = UsageMonitor(store: store)
            let settings = AnyView(SettingsView(
                monitor: model,
                launchAtLogin: LaunchAtLoginController(),
                loginAntigravity: {}, connectAntigravity: {}, openAntigravity: {}, loginCodex: {},
                loginClaudeAccount: {},
                renameAccount: { _, _ in }, refreshAccount: { _ in }, loginAccount: { _ in },
                cancelLogin: { _ in }, authorizeKeychain: { _ in }, disconnectAccount: { _ in },
                setVisibleWindows: { _, _ in },
                initialProvider: scenario == "settings-claude" ? .claude : .codex
            ))
            let previewFlow = PopoverFlow()
            previewFlow.showingSettings = true
            previewFlow.measuredHeight = Theme.settingsHeight(accountCount: model.accounts.count)
            content = AnyView(LivePopover(
                monitor: model, selection: AccountSelection(), flow: previewFlow,
                actions: PopoverActions(), settingsView: settings
            ).frame(width: Theme.settingsWidth, height: Theme.settingsHeight(accountCount: model.accounts.count)))
        } else {
            let accounts = PreviewFixtures.accounts(scenario)
            let index = argument("--selected-account").flatMap(Int.init) ?? 0
            let selectedID = accounts.indices.contains(index) ? accounts[index].id : accounts.first?.id
            content = AnyView(PopoverView(
                accounts: accounts, notice: nil,
                now: PreviewFixtures.now, preview: true, selectedID: selectedID,
                measuredHeight: PopoverView.height(for: accounts, now: PreviewFixtures.now,
                                                  preview: true, selectedID: selectedID),
                actions: PopoverActions()
            ))
        }
        // Exercise the real borderless panel without a preview-only mask
        // that could hide square edges in the production surface.
        let host = NSHostingView(rootView: content)
        let window = PopoverPanel()
        window.setContentSize(host.fittingSize)
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // Menu material blends behind the window; keep the preview window
        // transparent so captures show the same translucency as the popover.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let output = argument("--capture") {
            DispatchQueue.main.async {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                do {
                    if CommandLine.arguments.contains("--capture-scroll-bottom") {
                        guard self.scrollPreviewToBottom(host) else { throw CocoaError(.featureUnsupported) }
                        host.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    // Liquid Glass and vibrant labels are WindowServer effects;
                    // cacheDisplay omits them and cannot verify the visible UI.
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output]
                    capture.terminationHandler = { process in
                        DispatchQueue.main.async {
                            guard process.terminationStatus == 0 else {
                                FileHandle.standardError.write(Data("Capture failed: screencapture exited \(process.terminationStatus)\n".utf8))
                                exit(1)
                            }
                            print("CAPTURED \(Int(host.bounds.width))x\(Int(host.bounds.height)) \(output)")
                            NSApp.terminate(nil)
                        }
                    }
                    try capture.run()
                } catch {
                    FileHandle.standardError.write(Data("Capture failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    private func scrollPreviewToBottom(_ host: NSView) -> Bool {
        var pending = [host]
        while let view = pending.popLast() {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height + 1 {
                let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                print("SCROLLED document=\(document.bounds.height) viewport=\(scroll.contentView.bounds.height) y=\(y)")
                return true
            }
            pending.append(contentsOf: view.subviews)
        }
        return false
    }

}
