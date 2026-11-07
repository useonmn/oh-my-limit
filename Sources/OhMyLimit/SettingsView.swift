import AppKit
import OhMyLimitCore
import SwiftUI

@MainActor
private final class AccountDraft: ObservableObject {
    @Published var selectedProvider: AccountProvider = .codex
    @Published var showAntigravityLocal = false
}

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    let loginAntigravity: () -> Void
    let connectAntigravity: () -> Void
    let openAntigravity: () -> Void
    let loginCodex: () -> Void
    let loginClaudeAccount: () -> Void
    let renameAccount: (UUID, String) -> Void
    let refreshAccount: (UUID) -> Void
    let loginAccount: (UUID) -> Void
    let cancelLogin: (UUID) -> Void
    let authorizeKeychain: (UUID) -> Void
    let disconnectAccount: (UUID) -> Void
    let setVisibleWindows: (UUID, Set<String>?) -> Void
    var initialProvider: AccountProvider = .codex
    @StateObject private var draft = AccountDraft()

    var body: some View {
        GeometryReader { proxy in
            DetailScrollView(width: proxy.size.width) {
                settingsContent
            }
        }
        .foregroundStyle(Theme.panelPrimary)
        .tint(Theme.mint)
        .onAppear {
            draft.selectedProvider = initialProvider
            launchAtLogin.refreshStatus()
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            panelGroup {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .font(Theme.settingsBody)
                .disabled(!launchAtLogin.isAvailable)
                if launchAtLogin.status == .requiresApproval {
                    Text("시스템 설정의 로그인 항목에서 허용해 주세요.")
                        .font(Theme.caption)
                }
                if let error = launchAtLogin.errorMessage {
                    WarningLabel(text: error)
                }
            }
            if let notice = monitor.notice {
                WarningLabel(text: notice)
            }

            panelGroup {
                Text("연결된 계정").font(Theme.account)
                if monitor.accounts.isEmpty {
                    Text("아직 연결된 계정이 없습니다.")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                } else {
                    ForEach(monitor.accounts) { state in
                        AccountSettingsRow(
                            state: state,
                            onRename: { renameAccount(state.id, $0) },
                            onRefresh: { refreshAccount(state.id) },
                            onLogin: { loginAccount(state.id) },
                            onCancel: { cancelLogin(state.id) },
                            onAuthorizeKeychain: { authorizeKeychain(state.id) },
                            onDisconnect: { disconnectAccount(state.id) },
                            onSetVisibleWindows: { setVisibleWindows(state.id, $0) },
                            onMoveLeft: monitor.accounts.first?.id == state.id ? nil : { move(state.id, offset: -1) },
                            onMoveRight: monitor.accounts.last?.id == state.id ? nil : { move(state.id, offset: 1) }
                        )
                        .contextMenu {
                            Button("왼쪽으로 이동") { move(state.id, offset: -1) }
                                .disabled(monitor.accounts.first?.id == state.id)
                            Button("오른쪽으로 이동") { move(state.id, offset: 1) }
                                .disabled(monitor.accounts.last?.id == state.id)
                        }
                    }
                }
            }

            panelGroup {
                Text("계정 추가").font(Theme.account)
                Picker("서비스", selection: $draft.selectedProvider) {
                    Text("Codex").tag(AccountProvider.codex)
                    Text("Claude").tag(AccountProvider.claude)
                    Text("Antigravity").tag(AccountProvider.antigravity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                connectionActions
            }
        }
        .padding(Theme.panelInset)
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = monitor.accounts.firstIndex(where: { $0.id == id }) else { return }
        _ = monitor.move(id, to: index + offset)
    }

    @ViewBuilder
    private var connectionActions: some View {
        switch draft.selectedProvider {
        case .codex:
            Button(action: loginCodex) {
                Text("ChatGPT 계정 연결").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.accounts.contains(where: \.isLoggingIn))
            Text("브라우저에서 ChatGPT에 로그인하면 앱 키체인에 저장합니다. Codex CLI는 필요하지 않습니다.")
                .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .claude:
            Button(action: loginClaudeAccount) {
                Text("Claude 계정 연결").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.accounts.contains(where: \.isLoggingIn))
            Text("사용량 읽기 권한만 받아 앱 키체인에 저장합니다. Claude Code는 필요하지 않습니다.")
                .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .antigravity:
            Button(action: loginAntigravity) {
                Text("Google 계정 연결").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.accounts.contains(where: \.isLoggingIn))
            DisclosureGroup("로컬 앱·CLI로 연결", isExpanded: $draft.showAntigravityLocal) {
                HStack(spacing: Theme.compact) {
                    Button("현재 로컬 계정 연결", action: connectAntigravity)
                        .disabled(monitor.accounts.contains {
                            $0.profile.provider == .antigravity && $0.profile.authentication == .local
                        })
                    Button("앱 열기", action: openAntigravity)
                }
                .buttonStyle(.bordered)
                .padding(.top, Theme.compact)
            }
            .font(Theme.settingsBody)
        }
    }

    private func panelGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.compact, content: content)
            .padding(Theme.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuGroup(radius: Theme.panelGroupRadius)
    }
}

@MainActor
private final class AliasDraft: ObservableObject {
    @Published var name = ""
    @Published var isEditing = false
}

/// One connected account with actions inside the compact account list.
private struct AccountSettingsRow: View {
    let state: AccountState
    let onRename: (String) -> Void
    let onRefresh: () -> Void
    let onLogin: () -> Void
    let onCancel: () -> Void
    let onAuthorizeKeychain: () -> Void
    let onDisconnect: () -> Void
    let onSetVisibleWindows: (Set<String>?) -> Void
    let onMoveLeft: (() -> Void)?
    let onMoveRight: (() -> Void)?
    @StateObject private var draft = AliasDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.small) {
            HStack(spacing: Theme.compact) {
                ProviderMark(provider: state.profile.provider)
                    .frame(width: 14, height: 14)
                if draft.isEditing {
                    TextField("별칭", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAlias)
                    Button("저장", action: saveAlias)
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("취소") { draft.isEditing = false }
                } else {
                    VStack(alignment: .leading, spacing: Theme.small) {
                        HStack(spacing: Theme.compact) {
                            Text(state.profile.name).font(Theme.settingsBody.weight(.semibold))
                                .lineLimit(1).help(state.profile.name)
                            Spacer(minLength: 0)
                            if state.error == nil {
                                Text(status).font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                                    .lineLimit(1)
                            } else {
                                WarningLabel(text: status).lineLimit(1)
                            }
                        }
                        Text(connectionDescription)
                            .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(connectionDescription)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("별칭 수정") {
                            draft.name = state.profile.name
                            draft.isEditing = true
                        }
                        Button("새로고침", action: onRefresh)
                            .disabled(state.isRefreshing || state.isLoggingIn)
                        if state.isLoggingIn {
                            Button("로그인 취소", action: onCancel)
                        } else {
                            Button(loginLabel, action: onLogin)
                        }
                        Divider()
                        Button("왼쪽으로 이동") { onMoveLeft?() }.disabled(onMoveLeft == nil)
                        Button("오른쪽으로 이동") { onMoveRight?() }.disabled(onMoveRight == nil)
                        Divider()
                        Button(state.profile.authentication == .oauth
                               ? "연결 해제 (앱 인증 삭제)" : "연결 해제 (로그인 유지)",
                               role: .destructive, action: onDisconnect)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(state.profile.name) 계정 동작")
                }
            }
            .buttonStyle(.borderless)
            if !draft.isEditing {
                modelVisibility
            }
            if let error = state.error {
                WarningLabel(text: error)
            }
            if state.needsKeychainAccess && !state.isLoggingIn {
                Button("키체인 접근 허용", action: onAuthorizeKeychain)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(state.isRefreshing)
            }
            if state.isLoggingIn {
                Button("로그인 취소", action: onCancel)
                    .font(Theme.caption).buttonStyle(.borderless).foregroundStyle(Theme.link)
            }
        }
        .onAppear { draft.name = state.profile.name }
        .onChange(of: state.profile.name) { draft.name = $1 }
    }

    /// Lets the user pick which quota windows (models) the popover and menu bar show. An inline
    /// checklist, because a menu closes after each pick and accounts can expose many models.
    @ViewBuilder
    private var modelVisibility: some View {
        if let windows = state.snapshot?.windows, windows.count > 1 {
            let visible = Set(state.visibleWindows.map(\.id))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Theme.panelSmall) {
                    ForEach(windows) { window in
                        Toggle(windowTitle(window), isOn: Binding(
                            get: { visible.contains(window.id) },
                            set: { isOn in
                                onSetVisibleWindows(isOn ? visible.union([window.id]) : visible.subtracting([window.id]))
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(visible == [window.id])
                    }
                    if state.hiddenWindowCount > 0 {
                        Button("모두 표시") { onSetVisibleWindows(nil) }
                            .buttonStyle(.borderless)
                    }
                }
                .font(Theme.caption)
                .padding(.top, Theme.panelSmall)
            } label: {
                Text(state.hiddenWindowCount == 0
                     ? "표시할 모델 · 전체"
                     : "표시할 모델 · \(visible.count)/\(windows.count)개")
                    .font(Theme.caption)
            }
            .accessibilityLabel("\(state.profile.name) 표시할 모델")
        }
    }

    private func windowTitle(_ window: CodexQuotaWindow) -> String {
        let duration = window.windowDurationMins.map(CodexQuotaWindow.durationLabel(minutes:))
        return [window.label, duration == window.label ? nil : duration].compactMap { $0 }.joined(separator: " · ")
    }

    private var status: String {
        if state.isLoggingIn { return "로그인 중" }
        if state.isRefreshing { return "확인 중" }
        if state.snapshot != nil { return state.isStale(at: Date()) ? "이전 값" : "정상" }
        if state.profile.oauthIdentity != nil { return "사용량 미확인" }
        return state.error == nil ? "로그인 필요" : "연결 확인 필요"
    }

    private var connectionDescription: String {
        let method: String
        if state.profile.authentication == .oauth {
            switch state.profile.provider {
            case .codex: method = "ChatGPT 직접 연결"
            case .claude: method = "Claude 직접 연결"
            case .antigravity: method = "Google 직접 연결"
            }
        } else {
            method = "로컬 연결"
        }
        guard let email = state.profile.oauthIdentity?.email ?? state.snapshot?.identity.email else { return method }
        return "\(method) · \(email)"
    }

    private var loginLabel: String {
        switch state.profile.provider {
        case .codex: "ChatGPT 다시 로그인"
        case .claude: "Claude 다시 로그인"
        case .antigravity: state.profile.authentication == .oauth ? "Google 다시 로그인" : "Antigravity 열기"
        }
    }

    private func saveAlias() {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onRename(draft.name)
        draft.isEditing = false
    }
}
