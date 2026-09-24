import AppKit
import Combine
import OhMyLimitCore
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var monitor: UsageMonitor?
    private var statusItem: NSStatusItem?
    private let panel = PopoverPanel()
    private let selection = AccountSelection()
    private let flow = PopoverFlow()
    private var previewWindow: NSWindow?
    private var previewDirectory: URL?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let scenario = argument("--preview") {
            showPreview(scenario)
            return
        }
        enableLaunchAtLogin()
        NSApp.setActivationPolicy(.accessory)
        let dataDirectory = argument("--data-directory").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OhMyLimit", isDirectory: true)
        let configured = UserDefaults.standard.string(forKey: "codexExecutablePath")
        let executable = configured.map { URL(fileURLWithPath: $0) } ?? CodexClient.findExecutable()
        let model = UsageMonitor(store: AccountStore(directory: dataDirectory), executableURL: executable)
        monitor = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("Oh My Limit 사용량")

        // Let the native surface composite directly over the desktop,
        // without an additional NSPopover frame material underneath it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentViewController = NSHostingController(rootView: LivePopover(
            monitor: model, selection: selection, flow: flow, actions: actions,
            settingsView: AnyView(settingsView(for: model))
        ))
        subscription = model.$accounts.combineLatest(model.$notice, model.$executableURL, selection.$selectedID)
            .combineLatest(flow.$showingSettings)
            .sink { [weak self] _, showingSettings in
                // @Published emits before storage commits. Native sizing can
                // render LivePopover, so wait until it can read the new state.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let monitor = self.monitor else { return }
                    let states = monitor.accounts
                    self.selection.reconcile(accountIDs: states.map(\.id))
                    self.updateStatus(states)
                    self.setPanelContentSize(NSSize(
                        width: Theme.width,
                        height: showingSettings ? Theme.settingsHeight(accountCount: states.count) : PopoverView.height(
                            for: states, notice: monitor.notice, hasCLI: monitor.executableURL != nil,
                            selectedID: self.selection.selectedID
                        )
                    ))
                }
            }
        // Global monitors observe clicks in other apps even when we are
        // inactive, so this closes the panel in every outside-click case.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitor?.refreshAll(manual: false)
                if let states = self?.monitor?.accounts { self?.updateStatus(states) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil
        )
        model.refreshAll(manual: false)
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.revealPopover() }
        }
        if CommandLine.arguments.contains("--settings") {
            // Defer like --open: the status item's window is not placed yet,
            // so positioning now would use a degenerate frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showSettings() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        guard let monitor else { return .terminateNow }
        Task { @MainActor in
            await monitor.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }

    private var actions: PopoverActions {
        PopoverActions(
            selectAccount: { [weak self] id in self?.selection.select(id) },
            refreshAll: { [weak self] in self?.monitor?.refreshAll() },
            settings: { [weak self] in self?.showSettings() },
            connectCurrent: { [weak self] in self?.connectCurrent() },
            addAccount: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            dismissNotice: { [weak self] in self?.monitor?.clearNotice() },
            refresh: { [weak self] id in self?.monitor?.refresh(id) },
            authorizeKeychain: { [weak self] id in self?.monitor?.authorizeKeychain(id) },
            login: { [weak self] id in self?.login(id) },
            cancel: { [weak self] id in self?.monitor?.cancel(id) },
            disconnect: { [weak self] id in self?.monitor?.disconnect(id) },
            moveAccount: { [weak self] id, index in self?.monitor?.move(id, to: index) }
        )
    }

    private func updateStatus(_ states: [AccountState]) {
        let now = Date()
        let values = states.map { state in
            guard let window = state.menuWindow,
                  !(window.resetsAt.map { $0 <= now } ?? false) else { return "—" }
            var text = (state.isStale(at: now) ? "~" : "") + String(format: "%.0f%%", window.usedPercent)
            if window.windowDurationMins == 10_080, let resetsAt = window.resetsAt {
                text += "·" + Self.resetCountdown(until: resetsAt, from: now)
            }
            return text
        }
        guard let button = statusItem?.button else { return }
        if states.isEmpty {
            button.title = "Limit"
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.image = MenuBarSummary.image(for: zip(states, values).map {
                (provider: $0.0.profile.provider, text: $0.1)
            })
            button.imagePosition = .imageOnly
        }
        let names = zip(states, values).map {
            "\($0.0.profile.name) · \($0.0.profile.provider.displayName): \($0.1)"
        }.joined(separator: "\n")
        button.toolTip = "사용률 · 주간 우선 · ~ 표시는 마지막 확인값 · % 뒤는 주간 초기화까지\n\(names)"
        button.setAccessibilityLabel(names.isEmpty ? "Oh My Limit" : "Oh My Limit\n\(names)")
    }

    /// Compact countdown for the menu bar: "3d15h", "15h", or "42m".
    private static func resetCountdown(until date: Date, from now: Date) -> String {
        let minutes = max(1, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    @objc private func togglePopover() {
        if panel.isVisible { closePanel() } else { revealPopover() }
    }

    private func revealPopover() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        if !panel.isVisible {
            positionPanel(relativeTo: button, in: buttonWindow)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.orderFront(nil)
            } else {
                panel.alphaValue = 0
                panel.orderFront(nil)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        // Reclaim key status a tick later; dismissing the settings menu can
        // steal it back, leaving the panel unable to receive keyboard input.
        DispatchQueue.main.async {
            self.panel.makeKey()
        }
        monitor?.refreshAll(manual: false)
    }

    private func positionPanel(relativeTo button: NSView, in window: NSWindow) {
        // convertToScreen is deprecated; the status bar window's frame is
        // already in screen coordinates, so offset the button rect manually.
        let inWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = inWindow.offsetBy(dx: window.frame.origin.x, dy: window.frame.origin.y)
        FileHandle.standardError.write("[dbg] winFrame=\(window.frame) inWindow=\(inWindow) buttonFrame=\(buttonFrame) panelSize=\(panel.frame.size)\n".data(using: .utf8)!)
        let size = panel.frame.size
        var x = buttonFrame.midX - size.width / 2
        if let screen = window.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 4),
                    screen.visibleFrame.maxX - size.width - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: buttonFrame.minY - 6 - size.height))
    }

    private func setPanelContentSize(_ size: NSSize) {
        let top = panel.frame.maxY
        panel.setContentSize(size)
        // Keep the top edge pinned so a visible panel grows downward.
        if panel.isVisible {
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        flow.showingSettings = false
    }

    @objc private func woke() { monitor?.refreshAll(manual: false) }

    private func connectCurrent() {
        guard let monitor else { return }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        if let id = monitor.connectExisting(home: home, name: "현재 Codex") {
            selection.select(id)
            monitor.refresh(id)
            flow.showingSettings = false
        }
    }

    private func login(_ id: UUID) {
        selection.select(id)
        if let profile = monitor?.accounts.first(where: { $0.id == id })?.profile,
           profile.provider == .claude {
            loginClaudeCode()
            return
        }
        if let profile = monitor?.accounts.first(where: { $0.id == id })?.profile,
           profile.provider == .antigravity && profile.authentication == .local {
            openAntigravity()
            return
        }
        monitor?.login(id) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
    }

    private func connectAntigravity() {
        guard let id = monitor?.connectAntigravity() else { return }
        selection.select(id)
        monitor?.refresh(id)
        flow.showingSettings = false
    }

    private func openAntigravity() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Antigravity.app", "/Applications/Antigravity IDE.app",
            "\(home)/Applications/Antigravity.app", "\(home)/Applications/Antigravity IDE.app"
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
           NSWorkspace.shared.open(URL(fileURLWithPath: path)) { return }
        NSWorkspace.shared.open(URL(string: "https://antigravity.google/download")!)
    }

    private func loginClaudeCode() {
        guard let executable = ClaudeClient.findExecutable() else {
            showClaudeLoginError(ClaudeClientError.cliMissing)
            return
        }
        guard let monitor else { return }
        do {
            let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            let script = try ClaudeClient.prepareLoginCommand(
                in: monitor.store.directory.appendingPathComponent("LoginCommands", isDirectory: true),
                executableURL: executable, configDirectory: config
            )
            NSWorkspace.shared.open(
                [script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] _, error in
                guard let error else { return }
                try? FileManager.default.removeItem(at: script)
                Task { @MainActor [weak self] in self?.showClaudeLoginError(error) }
            }
        } catch {
            showClaudeLoginError(error)
        }
    }

    private func showClaudeLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Claude Code 로그인을 시작하지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func connectClaude() {
        guard let monitor else { return }
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        if let id = monitor.connectClaude(home: home) {
            selection.select(id)
            monitor.refresh(id)
            flow.showingSettings = false
        }
    }

    private func showSettings() {
        flow.showingSettings = true
        revealPopover()
    }

    private func settingsView(for monitor: UsageMonitor) -> SettingsView {
        SettingsView(
            monitor: monitor,
            chooseExecutable: { [weak self] in self?.chooseExecutable() },
            connectCurrent: { [weak self] in self?.connectCurrent() },
            chooseHome: { [weak self] name in self?.chooseHome(name: name) },
            addAccount: { [weak self] name in
                guard let self, let id = self.monitor?.createAccount(name: name) else { return }
                self.login(id)
                self.flow.showingSettings = false
            },
            loginAntigravity: { [weak self] in
                guard let self, let id = self.monitor?.createAntigravityAccount() else { return }
                self.login(id)
                self.flow.showingSettings = false
            },
            connectAntigravity: { [weak self] in self?.connectAntigravity() },
            openAntigravity: { [weak self] in self?.openAntigravity() },
            loginCodex: { [weak self] in
                guard let self, let id = self.monitor?.createCodexAccount() else { return }
                self.login(id)
                self.flow.showingSettings = false
            },
            connectClaude: { [weak self] in self?.connectClaude() },
            loginClaude: { [weak self] in self?.loginClaudeCode() },
            renameAccount: { [weak self] id, name in self?.monitor?.rename(id, to: name) },
            refreshAccount: { [weak self] id in self?.monitor?.refresh(id) },
            loginAccount: { [weak self] id in self?.login(id) },
            cancelLogin: { [weak self] id in self?.monitor?.cancel(id) },
            authorizeKeychain: { [weak self] id in self?.monitor?.authorizeKeychain(id) },
            disconnectAccount: { [weak self] id in self?.monitor?.disconnect(id) }
        )
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Codex 실행 파일 선택"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = monitor?.executableURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        monitor?.setExecutable(url)
        if monitor?.executableURL == url {
            UserDefaults.standard.set(url.path, forKey: "codexExecutablePath")
            monitor?.refreshAll()
        }
    }

    private func chooseHome(name: String) {
        let panel = NSOpenPanel()
        panel.title = "기존 Codex 홈 폴더 선택"
        panel.message = "auth.json 또는 Codex 인증 저장소를 사용하는 홈 폴더를 선택하세요."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url,
              let id = monitor?.connectExisting(home: url, name: name) else { return }
        selection.select(id)
        monitor?.refresh(id)
        flow.showingSettings = false
    }

    private func showPreview(_ scenario: String) {
        NSApp.setActivationPolicy(.regular)
        if let appearance = argument("--appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let content: AnyView
        if scenario == "settings" || scenario == "settings-connected" {
            let store = AccountStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            previewDirectory = store.directory
            if scenario == "settings-connected" {
                do {
                    try store.save([
                        AccountProfile(name: "개인", homePath: store.directory.path, isManaged: false,
                                       authentication: .oauth, oauthIdentity: CodexIdentity(email: "personal@example.com")),
                        AccountProfile(name: "업무", homePath: "/preview/codex", isManaged: false),
                        AccountProfile(name: "Claude", homePath: "/preview/claude", isManaged: false, provider: .claude),
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
            let model = UsageMonitor(store: store, executableURL: CodexClient.findExecutable())
            let settings = AnyView(SettingsView(
                monitor: model, chooseExecutable: {}, connectCurrent: {}, chooseHome: { _ in }, addAccount: { _ in },
                loginAntigravity: {}, connectAntigravity: {}, openAntigravity: {}, loginCodex: {},
                connectClaude: {}, loginClaude: {},
                renameAccount: { _, _ in }, refreshAccount: { _ in }, loginAccount: { _ in },
                cancelLogin: { _ in }, authorizeKeychain: { _ in }, disconnectAccount: { _ in }
            ))
            let previewFlow = PopoverFlow()
            previewFlow.showingSettings = true
            content = AnyView(LivePopover(
                monitor: model, selection: AccountSelection(), flow: previewFlow,
                actions: PopoverActions(), settingsView: settings
            ).frame(width: Theme.width, height: Theme.settingsHeight(accountCount: model.accounts.count)))
        } else {
            let accounts = PreviewFixtures.accounts(scenario)
            let index = argument("--selected-account").flatMap(Int.init) ?? 0
            let selectedID = accounts.indices.contains(index) ? accounts[index].id : accounts.first?.id
            content = AnyView(PopoverView(
                accounts: accounts, notice: nil,
                hasCLI: scenario != "missing-cli" && !scenario.hasPrefix("antigravity"),
                now: PreviewFixtures.now, preview: true, selectedID: selectedID,
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

    private func argument(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

/// Borderless panel that can become key so keyboard shortcuts work.
private final class PopoverPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--probe-antigravity")
    || CommandLine.arguments.contains("--probe-claude") {
    let antigravity = CommandLine.arguments.contains("--probe-antigravity")
    let claude = CommandLine.arguments.contains("--probe-claude")
    Task { @MainActor in
        do {
            let snapshot: CodexUsageSnapshot
            if antigravity {
                let executable: URL?
                if let index = CommandLine.arguments.firstIndex(of: "--antigravity-cli"),
                   index + 1 < CommandLine.arguments.count {
                    executable = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                } else {
                    executable = nil
                }
                snapshot = try await AntigravityClient(executableURL: executable).fetchUsage()
            } else if claude {
                let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
                snapshot = try await ClaudeClient().fetchUsage(home: home)
            } else {
                guard let executable = CodexClient.findExecutable() else { throw CocoaError(.executableNotLoadable) }
                let home: URL
                if let index = CommandLine.arguments.firstIndex(of: "--codex-home"), index + 1 < CommandLine.arguments.count {
                    home = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                } else {
                    home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                }
                snapshot = try await CodexClient(executableURL: executable).fetchUsage(home: home)
            }
            struct ProbeResult: Encodable {
                let plan: String?
                let windows: [CodexQuotaWindow]
                let fetchedAt: Date
                let source: UsageSource?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ProbeResult(
                plan: snapshot.identity.planType, windows: snapshot.windows, fetchedAt: snapshot.fetchedAt,
                source: snapshot.source
            ))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        } catch {
            let provider = claude ? "Claude" : antigravity ? "Antigravity" : "Codex"
            FileHandle.standardError.write(Data("\(provider): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.run()
}
