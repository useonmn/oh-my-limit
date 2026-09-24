import AppKit
import OhMyLimitCore
import SwiftUI

@MainActor
private final class AccountDraft: ObservableObject {
    @Published var name = ""
    @Published var selectedProvider: AccountProvider = .codex
    @Published var showCodexLocal = false
    @Published var showAntigravityLocal = false
}

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    let chooseExecutable: () -> Void
    let connectCurrent: () -> Void
    let chooseHome: (String) -> Void
    let addAccount: (String) -> Void
    let loginAntigravity: () -> Void
    let connectAntigravity: () -> Void
    let openAntigravity: () -> Void
    let loginCodex: () -> Void
    let connectClaude: () -> Void
    let loginClaude: () -> Void
    let renameAccount: (UUID, String) -> Void
    let refreshAccount: (UUID) -> Void
    let loginAccount: (UUID) -> Void
    let cancelLogin: (UUID) -> Void
    let authorizeKeychain: (UUID) -> Void
    let disconnectAccount: (UUID) -> Void
    @StateObject private var draft = AccountDraft()

    var body: some View {
        GeometryReader { proxy in
            DetailScrollView(width: proxy.size.width) {
                settingsContent
            }
        }
        .foregroundStyle(Theme.panelPrimary)
        .tint(Theme.mint)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let notice = monitor.notice {
                Text(notice).font(Theme.body).foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
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
                            onDisconnect: { disconnectAccount(state.id) }
                        )
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
        .padding(Theme.padding)
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
            DisclosureGroup("Codex CLI로 연결", isExpanded: $draft.showCodexLocal) {
                VStack(alignment: .leading, spacing: Theme.compact) {
                    Button("현재 Codex 계정 연결", action: connectCurrent)
                    Button("기존 Codex 폴더 선택…") { chooseHome(draft.name) }
                    TextField("별도 계정 이름", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("별도 Codex 계정 이름")
                    Button("별도 계정으로 로그인") { addAccount(draft.name) }
                        .disabled(monitor.executableURL == nil || monitor.accounts.contains(where: \.isLoggingIn))
                    Button("CLI 실행 파일 선택…", action: chooseExecutable)
                        .help(monitor.executableURL?.path ?? "Codex CLI를 찾지 못했습니다.")
                    if monitor.executableURL == nil {
                        Link("Codex CLI 설치 안내", destination: URL(string: "https://developers.openai.com/codex/cli")!)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, Theme.compact)
            }
            .font(Theme.panelBody)
        case .claude:
            if monitor.accounts.contains(where: { $0.profile.provider == .claude }) {
                Text("이미 연결됨 · 위 계정 메뉴에서 다시 로그인")
                    .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
            } else {
                let hasCLI = ClaudeClient.findExecutable() != nil
                Button("1. Claude Code로 로그인…", action: loginClaude)
                    .disabled(!hasCLI)
                Button("2. 로그인된 계정 연결", action: connectClaude)
                    .buttonStyle(.borderedProminent)
                if !hasCLI {
                    Link("Claude Code 설치 안내", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                }
                Text("이미 로그인했다면 1단계를 건너뛰세요.")
                    .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
            }
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
            .font(Theme.panelBody)
        }
    }

    private func panelGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.compact, content: content)
            .padding(Theme.gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuGroup()
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
                            Text(state.profile.name).font(Theme.panelBody.weight(.semibold))
                                .lineLimit(1).help(state.profile.name)
                            Spacer(minLength: 0)
                            Text(status).font(Theme.caption)
                                .foregroundStyle(state.error == nil ? Theme.panelSecondary : Theme.warningText)
                                .lineLimit(1)
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
            if let error = state.error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.needsKeychainAccess && !state.isLoggingIn {
                Button("키체인 접근 허용", action: onAuthorizeKeychain)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(state.isRefreshing)
            }
            if state.isLoggingIn {
                Button("로그인 취소", action: onCancel)
                    .font(Theme.caption).buttonStyle(.borderless)
            }
        }
        .onAppear { draft.name = state.profile.name }
        .onChange(of: state.profile.name) { draft.name = $1 }
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
            method = state.profile.provider == .codex ? "ChatGPT 직접 연결" : "Google 직접 연결"
        } else if state.profile.isManaged {
            method = "앱 전용 Codex 폴더"
        } else {
            method = "로컬 연결"
        }
        guard let email = state.profile.oauthIdentity?.email ?? state.snapshot?.identity.email else { return method }
        return "\(method) · \(email)"
    }

    private var loginLabel: String {
        switch state.profile.provider {
        case .codex: state.profile.authentication == .oauth ? "ChatGPT 다시 로그인" : "Codex 다시 로그인"
        case .claude: "Claude Code로 로그인…"
        case .antigravity: state.profile.authentication == .oauth ? "Google 다시 로그인" : "Antigravity 열기"
        }
    }

    private func saveAlias() {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onRename(draft.name)
        draft.isEditing = false
    }
}
