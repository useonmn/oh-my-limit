import AppKit
import OhMyLimitCore
import SwiftUI

@MainActor
private final class AccountDraft: ObservableObject {
    @Published var name = ""
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
    let renameAccount: (UUID, String) -> Void
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
        VStack(alignment: .leading, spacing: Theme.large) {
                VStack(alignment: .leading, spacing: Theme.compact) {
                    Text("계정 연결 설정").font(Theme.title)
                    Text("Codex와 Antigravity의 사용량을 함께 확인합니다.")
                        .font(Theme.body).foregroundStyle(Theme.panelSecondary)
                }
                if !monitor.accounts.isEmpty {
                    panelGroup {
                        cardTitle("연결된 계정", provider: .codex)
                        ForEach(monitor.accounts) { state in
                            AccountSettingsRow(
                                state: state,
                                onRename: { renameAccount(state.id, $0) },
                                onDisconnect: { disconnectAccount(state.id) }
                            )
                        }
                    }
                }
                panelGroup {
                    cardTitle("Antigravity", provider: .antigravity)
                    Text("앱이나 CLI 설치 없이 Google 계정으로 로그인하세요. 여러 계정을 따로 연결할 수 있습니다.")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Google 계정으로 로그인", action: loginAntigravity)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(monitor.accounts.contains(where: \.isLoggingIn))
                    Text("이미 Antigravity 앱·CLI를 사용 중이라면")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                    HStack(spacing: Theme.gap) {
                        Button("현재 로컬 계정 연결", action: connectAntigravity)
                        Button("앱 열기", action: openAntigravity)
                    }
                    .buttonStyle(.bordered).font(Theme.panelBody)
                    Text("로컬 연결만 외부 앱의 계정 변경을 따라갑니다.")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                panelGroup {
                    cardTitle("Codex 직접 로그인", provider: .codex)
                    Text("codex CLI 없이 ChatGPT 계정으로 로그인해 사용량을 확인합니다. 여러 계정을 따로 연결할 수 있습니다.")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("ChatGPT 계정으로 로그인", action: loginCodex)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(monitor.accounts.contains(where: \.isLoggingIn))
                }
                panelGroup {
                    cardTitle("Codex 실행 파일", provider: .codex)
                    Text(monitor.executableURL?.path ?? "Codex를 찾지 못했습니다.")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.gap) {
                        Button("실행 파일 선택…", action: chooseExecutable)
                            .buttonStyle(.bordered)
                        Link("설치 안내", destination: URL(string: "https://developers.openai.com/codex/cli")!)
                            .foregroundStyle(Theme.mint)
                    }
                    .font(Theme.panelBody)
                }
                panelGroup {
                    cardTitle("Codex 계정 연결", provider: .codex)
                    TextField("계정 이름 (예: 개인, 업무)", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("새 계정 이름")
                    Button("새 계정으로 로그인") { addAccount(draft.name) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(monitor.executableURL == nil || monitor.accounts.contains(where: \.isLoggingIn))
                    Text("앱 전용 Codex 폴더에 따로 로그인합니다. 기존 터미널의 로그인은 바꾸지 않습니다.")
                        .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.gap) {
                        Button("현재 Codex 연결", action: connectCurrent)
                        Button("기존 Codex 폴더 선택…") { chooseHome(draft.name) }
                    }
                    .buttonStyle(.bordered).font(Theme.panelBody)
                }
                if let notice = monitor.notice {
                    Text(notice).font(Theme.body).foregroundStyle(Theme.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Theme.compact) {
                    Text("수집 방식").font(Theme.account)
                    Text("Codex는 60초, Antigravity는 5분마다 확인합니다. 실패 시 마지막 확인값을 유지하며 재시도 간격을 늘립니다.")
                    Text("Google·ChatGPT 직접 연결을 해제하면 이 앱에 저장한 인증정보도 삭제합니다. Codex와 로컬 연결은 외부 로그인을 유지합니다.")
                }
                .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.large)
    }

    private func cardTitle(_ title: String, provider: AccountProvider) -> some View {
        HStack(spacing: Theme.compact) {
            ProviderMark(provider: provider)
                .frame(width: 14, height: 14)
            Text(title).font(Theme.account)
        }
    }

    private func panelGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.compact, content: content)
            .padding(Theme.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuGroup()
    }
}

@MainActor
private final class AliasDraft: ObservableObject {
    @Published var name = ""
}

/// One connected account in settings: provider mark, editable alias, and
/// a disconnect button. The alias is the name shown on the account card.
private struct AccountSettingsRow: View {
    let state: AccountState
    let onRename: (String) -> Void
    let onDisconnect: () -> Void
    @StateObject private var draft = AliasDraft()

    var body: some View {
        HStack(spacing: Theme.compact) {
            ProviderMark(provider: state.profile.provider)
                .frame(width: 14, height: 14)
            TextField("별칭", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.panelBody)
                .onSubmit { onRename(draft.name) }
                .onAppear { draft.name = state.profile.name }
                .onChange(of: state.profile.name) { draft.name = $1 }
            let caption = state.profile.oauthIdentity?.email
                ?? (state.profile.authentication == .local ? "로컬 연결" : nil)
            if let caption {
                Text(caption).font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            Button("저장") { onRename(draft.name) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(trimmed.isEmpty || trimmed == state.profile.name)
            Button("해제", action: onDisconnect)
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
