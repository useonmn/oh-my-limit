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
    var previewWindow: NSWindow?
    var previewDirectory: URL?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var outsideClickMonitor: Any?
    private let launchAtLogin = LaunchAtLoginController()
    private var previousApplication: NSRunningApplication?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownDeadline: DispatchWorkItem?
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let scenario = argument("--preview") {
            showPreview(scenario)
            return
        }
        launchAtLogin.prepareForNormalLaunch()
        NSApp.setActivationPolicy(.accessory)
        let dataDirectory = argument("--data-directory").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OhMyLimit", isDirectory: true)
        let model = UsageMonitor(store: AccountStore(directory: dataDirectory))
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
        subscription = model.$accounts.combineLatest(model.$notice)
            .combineLatest(flow.$showingSettings)
            .sink { [weak self] _ in
                // @Published emits before storage commits. Native sizing can
                // render LivePopover, so wait until it can read the new state.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let monitor = self.monitor else { return }
                    let states = monitor.accounts
                    self.selection.reconcile(accountIDs: states.map(\.id))
                    self.updateStatus(states)
                    self.updatePanelSize()
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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitor?.refreshAll(manual: false)
                if let states = self?.monitor?.accounts { self?.updateStatus(states) }
                self?.updatePanelSize()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissPanel), name: NSApplication.didResignActiveNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(dismissPanel), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(dismissPanel), name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        updatePanelSize()
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
        guard shutdownTask == nil else { return .terminateLater }
        let deadline = DispatchWorkItem { [weak self] in
            self?.finishTermination(sender)
        }
        shutdownDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
        shutdownTask = Task { @MainActor [weak self] in
            await monitor.stopAndWait()
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        shutdownDeadline?.cancel()
        shutdownTask?.cancel()
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }

    private var actions: PopoverActions {
        PopoverActions(
            selectAccount: { [weak self] id in
                self?.select(id)
            },
            refreshAll: { [weak self] in self?.monitor?.refreshAll() },
            settings: { [weak self] in self?.showSettings() },
            addAccount: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            dismissNotice: { [weak self] in self?.monitor?.clearNotice() },
            refresh: { [weak self] id in self?.monitor?.refresh(id) },
            authorizeKeychain: { [weak self] id in self?.monitor?.authorizeKeychain(id) },
            login: { [weak self] id in self?.login(id) },
            cancel: { [weak self] id in self?.monitor?.cancel(id) },
            disconnect: { [weak self] id in self?.monitor?.disconnect(id) },
            moveAccount: { [weak self] id, index in _ = self?.monitor?.move(id, to: index) }
        )
    }

    private func updateStatus(_ states: [AccountState]) {
        let now = Date()
        guard let button = statusItem?.button else { return }
        if states.isEmpty {
            button.title = ""
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
            button.imagePosition = .imageOnly
        } else {
            button.title = ""
            button.image = MenuBarSummary.image(for: MenuBarPresentation.fit(
                states, at: now, limit: Theme.menuBarAccountLimit,
                maxWidth: Double(Theme.menuBarMaximumWidth),
                width: { Double(MenuBarSummary.width(for: $0)) }
            ))
            button.imagePosition = .imageOnly
        }
        button.toolTip = MenuBarPresentation.tooltip(for: states, at: now)
        button.setAccessibilityLabel(MenuBarPresentation.accessibilityLabel(for: states, at: now))
    }

    @objc private func togglePopover() {
        if panel.isVisible { closePanel() } else { revealPopover() }
    }

    private func revealPopover() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        if !panel.isVisible {
            previousApplication = NSWorkspace.shared.frontmostApplication
            updatePanelSize()
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
        // Reclaim key status a tick later; dismissing the settings menu can
        // steal it back, leaving the panel unable to receive keyboard input.
        DispatchQueue.main.async {
            if self.panel.isVisible { self.panel.makeKey() }
        }
        monitor?.refreshAll(manual: false)
    }

    private func positionPanel(relativeTo button: NSView, in window: NSWindow) {
        // convertToScreen is deprecated; the status bar window's frame is
        // already in screen coordinates, so offset the button rect manually.
        let inWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = inWindow.offsetBy(dx: window.frame.origin.x, dy: window.frame.origin.y)
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
        let center = panel.frame.midX
        panel.setContentSize(size)
        // Keep the top edge pinned so a visible panel grows downward, and keep it
        // centered because settings mode is wider than the usage popover.
        if panel.isVisible {
            var x = center - panel.frame.width / 2
            if let screen = panel.screen ?? NSScreen.main {
                x = min(max(x, screen.visibleFrame.minX + 4),
                        screen.visibleFrame.maxX - panel.frame.width - 4)
            }
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        }
    }

    private func updatePanelSize() {
        guard let monitor else { return }
        let now = Date()
        flow.now = now
        let height = flow.showingSettings
            ? Theme.settingsHeight(accountCount: monitor.accounts.count)
            : PopoverView.height(for: monitor.accounts, notice: monitor.notice,
                                 now: now, selectedID: selection.selectedID)
        flow.measuredHeight = height
        setPanelContentSize(NSSize(
            width: flow.showingSettings ? Theme.settingsWidth : Theme.width, height: height
        ))
    }

    // Resize in the same pass that draws a changed selection; the deferred
    // account sink would otherwise show it one frame at the old height.
    private func select(_ id: UUID) {
        guard selection.selectedID != id else { return }
        selection.select(id)
        if !flow.showingSettings { updatePanelSize() }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        flow.showingSettings = false
        // Do not steal focus back if the user already switched to another app.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }

    @objc private func dismissPanel() { closePanel() }

    @objc private func woke() { monitor?.refreshAll(manual: false) }

    private func login(_ id: UUID) {
        select(id)
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
        select(id)
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

    private func showSettings() {
        flow.showingSettings = true
        revealPopover()
    }

    private func settingsView(for monitor: UsageMonitor) -> SettingsView {
        SettingsView(
            monitor: monitor,
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
            loginClaudeAccount: { [weak self] in
                guard let self, let id = self.monitor?.createClaudeAccount() else { return }
                self.login(id)
                self.flow.showingSettings = false
            },
            renameAccount: { [weak self] id, name in self?.monitor?.rename(id, to: name) },
            refreshAccount: { [weak self] id in self?.monitor?.refresh(id) },
            loginAccount: { [weak self] id in self?.login(id) },
            cancelLogin: { [weak self] id in self?.monitor?.cancel(id) },
            authorizeKeychain: { [weak self] id in self?.monitor?.authorizeKeychain(id) },
            disconnectAccount: { [weak self] id in self?.monitor?.disconnect(id) }
        )
    }

    func argument(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
}

/// Borderless panel that can become key so keyboard shortcuts work.
final class PopoverPanel: NSPanel {
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

if CommandLine.arguments.contains("--probe-antigravity") {
    runAntigravityProbe()
} else {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.run()
}
