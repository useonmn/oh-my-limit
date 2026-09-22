import AppKit
import OhMyLimitCore
import SwiftUI

struct AccountCard: View {
    let state: AccountState
    let now: Date
    let refresh: () -> Void
    let authorizeKeychain: () -> Void
    let login: () -> Void
    let cancel: () -> Void
    let disconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.padding) {
            HStack(alignment: .top) {
                ProviderMark(provider: state.profile.provider)
                    .frame(width: 18, height: 18).padding(6)
                    .padding(.top, Theme.small)
                VStack(alignment: .leading, spacing: Theme.small) {
                    Text(state.profile.name).font(Theme.panelAccount).lineLimit(1)
                        .help(state.profile.name)
                    if let snapshot = state.snapshot {
                        let plan = state.profile.provider == .codex
                            ? snapshot.identity.planType?.capitalized : snapshot.identity.planType
                        let identity = [snapshot.identity.email, plan]
                            .compactMap { $0 }.joined(separator: " · ")
                        Text(identity.isEmpty
                             ? (state.profile.provider == .antigravity ? "로컬 계정 · 이메일 미제공" : "계정 정보 미제공")
                             : identity)
                            .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                            .lineLimit(1).help(snapshot.identity.email ?? "")
                    } else if let email = state.profile.oauthIdentity?.email {
                        Text(email).font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                            .lineLimit(1).help(email)
                    } else {
                        Text(state.profile.provider == .antigravity
                             ? (state.profile.authentication == .oauth ? "Google 직접 로그인" : "Antigravity 로컬 계정")
                             : (state.profile.authentication == .oauth ? "ChatGPT 직접 로그인"
                                : state.profile.isManaged ? "별도 로그인 계정" : "기존 Codex 계정"))
                            .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                    }
                }
                Spacer(minLength: Theme.compact)
                Menu {
                    Button("새로고침", action: refresh).disabled(state.isRefreshing || state.isLoggingIn)
                    Button(state.profile.provider == .antigravity && state.profile.authentication == .local
                           ? "Antigravity 열기" : "다시 로그인",
                           action: login).disabled(state.isLoggingIn)
                    Divider()
                    Button("연결 해제", action: disconnect)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("계정 동작")
                .accessibilityLabel("\(state.profile.name) 계정 메뉴")
            }

            if state.isLoggingIn {
                HStack(spacing: Theme.compact) {
                    ProgressView().controlSize(.small)
                    Text("브라우저에서 로그인을 완료해 주세요.")
                        .font(Theme.panelBody).fixedSize(horizontal: false, vertical: true)
                }
                Button("로그인 취소", action: cancel).buttonStyle(.borderless).controlSize(.small)
                    .foregroundStyle(Theme.mint)
            } else if let snapshot = state.snapshot {
                ForEach(snapshot.windows) { window in
                    QuotaRow(window: window, now: now)
                }
                if snapshot.windows.isEmpty {
                    Text("조회된 사용량 한도 정보가 없습니다.")
                        .font(Theme.panelBody).foregroundStyle(Theme.panelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.ordinaryUsageAllowed == false {
                    Label("서버에서 기본 사용량이 제한된 상태입니다.", systemImage: "exclamationmark.circle")
                        .font(Theme.caption).foregroundStyle(Theme.panelWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let credits = snapshot.credits {
                    HStack {
                        Text("크레딧").foregroundStyle(Theme.panelSecondary)
                        Spacer()
                        Text(credits).monospacedDigit()
                    }
                    .font(Theme.caption)
                }
            } else if state.isRefreshing {
                HStack(spacing: Theme.compact) {
                    ProgressView().controlSize(.small)
                    Text("사용량을 확인하고 있습니다.").font(Theme.panelBody)
                }
                .padding(.vertical, Theme.compact)
            } else {
                Text(state.profile.oauthIdentity == nil ? "아직 확인한 사용량이 없습니다." : "로그인됨 · 사용량 미확인")
                    .font(Theme.panelBody).foregroundStyle(Theme.panelSecondary)
                if state.profile.oauthIdentity != nil {
                    if !state.needsKeychainAccess {
                        Button("사용량 다시 확인", action: refresh)
                            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Theme.mint)
                    }
                } else {
                    Button(state.profile.provider == .antigravity
                           ? (state.profile.authentication == .oauth ? "Google 로그인" : "Antigravity 열기 / 설치")
                           : (state.profile.authentication == .oauth ? "ChatGPT 로그인" : "Codex 로그인"), action: login)
                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Theme.mint)
                }
            }

            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.panelWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.needsKeychainAccess && !state.isLoggingIn {
                Button("키체인 접근 허용", action: authorizeKeychain)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(state.isRefreshing)
                    .accessibilityLabel("\(state.profile.name) 키체인 접근 허용")
                Text("macOS 권한 창에서 ‘항상 허용’을 선택해 주세요. 기존 로그인은 유지됩니다.")
                    .font(Theme.caption).foregroundStyle(Theme.panelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = state.snapshot {
                HStack(spacing: Theme.small) {
                    if state.isRefreshing { ProgressView().controlSize(.mini) }
                    Text("마지막 확인 · \(ageDescription(snapshot.fetchedAt))")
                    if state.isStale(at: now) {
                        Text("· 이전 값").foregroundStyle(Theme.panelWarning)
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.panelSecondary)
                .help(snapshot.fetchedAt.formatted(date: .complete, time: .complete))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ageDescription(_ date: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        if minutes < 1_440 { return "\(minutes / 60)시간 전" }
        return "\(minutes / 1_440)일 전"
    }
}

struct PopoverActions {
    var selectAccount: (UUID) -> Void = { _ in }
    var refreshAll: () -> Void = {}
    var settings: () -> Void = {}
    var connectCurrent: () -> Void = {}
    var addAccount: () -> Void = {}
    var quit: () -> Void = {}
    var dismissNotice: () -> Void = {}
    var refresh: (UUID) -> Void = { _ in }
    var authorizeKeychain: (UUID) -> Void = { _ in }
    var login: (UUID) -> Void = { _ in }
    var cancel: (UUID) -> Void = { _ in }
    var disconnect: (UUID) -> Void = { _ in }
    var moveAccount: (UUID, Int) -> Void = { _, _ in }
}

@MainActor
private final class RingDragState: ObservableObject {
    @Published var draggingID: UUID?
    @Published var startIndex = 0
    @Published var lastDesired = 0
    @Published var offset: CGFloat = 0
}

struct PopoverView: View {
    private static let slotWidth = Theme.accountButtonWidth + Theme.compact
    let accounts: [AccountState]
    let notice: String?
    let hasCLI: Bool
    let now: Date
    var preview = false
    var selectedID: UUID?
    var actions = PopoverActions()
    @StateObject private var drag = RingDragState()

    private var selectedAccount: AccountState? {
        accounts.first { $0.id == selectedID } ?? accounts.first
    }

    /// Measure the selected detail only; the header and account selector stay fixed.
    static func height(
        for accounts: [AccountState], notice: String? = nil, hasCLI: Bool = true,
        now: Date = .now, preview: Bool = false, selectedID: UUID? = nil
    ) -> CGFloat {
        let view = PopoverView(accounts: accounts, notice: notice, hasCLI: hasCLI, now: now,
                               preview: preview, selectedID: selectedID)
        let host = NSHostingView(rootView: view.naturalLayout)
        return min(620, max(192, ceil(host.fittingSize.height)))
    }

    private var naturalLayout: some View {
        VStack(spacing: 0) {
            header
            if !accounts.isEmpty { accountSelector }
            content(scrolling: false)
        }
        .frame(width: Theme.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !accounts.isEmpty { accountSelector }
            content(scrolling: true)
        }
        .frame(width: Theme.width, height: Self.height(
            for: accounts, notice: notice, hasCLI: hasCLI, now: now, preview: preview,
            selectedID: selectedID
        ))
        .foregroundStyle(Theme.panelPrimary)
        .tint(Theme.mint)
        .menuSurface()
    }

    private var header: some View {
        HStack(spacing: Theme.small) {
            if preview {
                Text("예시 데이터")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.panelSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay { Capsule().stroke(Theme.panelSeparator.opacity(0.8), lineWidth: 0.5) }
            }
            Spacer(minLength: Theme.small)
            if !accounts.isEmpty {
                Button(action: actions.refreshAll) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .disabled(accounts.contains { $0.isRefreshing || $0.isLoggingIn }
                          || (!hasCLI && accounts.allSatisfy { $0.profile.provider == .codex }))
                .help("새로고침 (⌘R)")
                .accessibilityLabel("모든 계정 새로고침")
            }
            Menu {
                Button("설정…", action: actions.settings).keyboardShortcut(",")
                Divider()
                Button("종료", action: actions.quit).keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("설정 및 종료")
            .accessibilityLabel("설정 및 종료")
        }
        .buttonStyle(.borderless)
        .font(Theme.panelBody)
        .foregroundStyle(Theme.panelSecondary)
        .padding(.horizontal, Theme.panelInset)
        .frame(height: 44)
    }

    private var accountSelector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.compact) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, state in
                        let duplicateName = accounts.filter { $0.profile.name == state.profile.name }.count > 1
                        AccountRing(
                            state: state, now: now,
                            name: state.profile.name + (duplicateName ? " \(index + 1)" : ""),
                            selected: state.id == selectedAccount?.id,
                            select: { actions.selectAccount(state.id) }
                        )
                        .id(state.id)
                        .offset(x: drag.draggingID == state.id
                                ? drag.offset - CGFloat(index - drag.startIndex) * Self.slotWidth : 0)
                        .zIndex(drag.draggingID == state.id ? 1 : 0)
                        .shadow(color: .black.opacity(drag.draggingID == state.id ? 0.4 : 0),
                                radius: 8, y: 4)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named("ringRow"))
                                .onChanged { value in
                                    if drag.draggingID != state.id {
                                        drag.draggingID = state.id
                                        drag.startIndex = index
                                        drag.lastDesired = index
                                    }
                                    drag.offset = value.translation.width
                                    let desired = min(max(Int(value.location.x / Self.slotWidth), 0),
                                                      accounts.count - 1)
                                    guard desired != drag.lastDesired else { return }
                                    drag.lastDesired = desired
                                    guard accounts[desired].id != state.id else { return }
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        actions.moveAccount(state.id, desired)
                                    }
                                }
                                .onEnded { _ in
                                    if drag.draggingID == state.id {
                                        drag.draggingID = nil
                                        drag.offset = 0
                                    }
                                }
                        )
                    }
                }
                .coordinateSpace(name: "ringRow")
                .frame(minWidth: Theme.width - Theme.panelInset * 2)
                .padding(.horizontal, Theme.panelInset)
                .padding(.vertical, Theme.small)
            }
            .onAppear {
                if let id = selectedAccount?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedAccount?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: accounts.count > 3 ? 188 : 172)
    }

    private func content(scrolling: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let notice {
                HStack(alignment: .top, spacing: Theme.compact) {
                    Text(notice).font(Theme.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: actions.dismissNotice) {
                        Image(systemName: "xmark").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless).accessibilityLabel("알림 닫기")
                }
                .foregroundStyle(Theme.panelWarning)
            }
            if accounts.isEmpty {
                emptyState
            } else {
                if !hasCLI && selectedAccount?.profile.provider == .codex {
                    VStack(alignment: .leading, spacing: Theme.small) {
                        Label("Codex CLI를 찾을 수 없습니다", systemImage: "terminal")
                            .font(Theme.panelAccount)
                        Button("설정에서 실행 파일 선택…", action: actions.settings)
                            .buttonStyle(.borderless).font(Theme.panelBody)
                            .foregroundStyle(Theme.mint)
                    }
                }
                if let state = selectedAccount {
                    Group {
                        if scrolling {
                            DetailScrollView(width: Theme.width - Theme.panelInset * 2) {
                                accountDetail(state)
                            }
                        } else {
                            accountDetail(state)
                        }
                    }
                    .menuGroup()
                    .id(state.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("account-detail-\(state.id.uuidString)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.panelInset)
        .padding(.top, Theme.compact)
        .padding(.bottom, Theme.panelInset)
    }

    private func accountDetail(_ state: AccountState) -> some View {
        AccountCard(
            state: state, now: now,
            refresh: { actions.refresh(state.id) },
            authorizeKeychain: { actions.authorizeKeychain(state.id) },
            login: { actions.login(state.id) },
            cancel: { actions.cancel(state.id) },
            disconnect: { actions.disconnect(state.id) }
        )
        .padding(Theme.padding)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Codex 또는 Antigravity를 연결해\n사용량과 초기화 시간을 확인하세요.")
                .font(Theme.panelBody).foregroundStyle(Theme.panelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.small) {
                Button(hasCLI ? "현재 Codex 계정 연결" : "Codex 실행 파일 선택…",
                       action: hasCLI ? actions.connectCurrent : actions.settings)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("다른 서비스·계정 연결…", action: actions.addAccount)
                    .buttonStyle(.borderless)
                    .font(Theme.panelBody)
                    .foregroundStyle(Theme.panelSecondary)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
        }
        .padding(.top, Theme.small)
    }
}

@MainActor
final class PopoverFlow: ObservableObject {
    @Published var showingSettings = false
}

struct LivePopover: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var selection: AccountSelection
    @ObservedObject var flow: PopoverFlow
    let actions: PopoverActions
    let settingsView: AnyView

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if flow.showingSettings {
                VStack(spacing: 0) {
                    HStack(spacing: Theme.small) {
                        Button(action: { flow.showingSettings = false }) {
                            Image(systemName: "chevron.left")
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("뒤로")
                        Text("설정").font(Theme.panelTitle)
                        Spacer(minLength: Theme.small)
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.panelBody)
                    .foregroundStyle(Theme.panelSecondary)
                    .padding(.horizontal, Theme.panelInset)
                    .frame(height: 44)
                    settingsView
                }
                .foregroundStyle(Theme.panelPrimary)
                .tint(Theme.mint)
                .menuSurface()
            } else {
                PopoverView(
                    accounts: monitor.accounts, notice: monitor.notice,
                    hasCLI: monitor.executableURL != nil, now: context.date,
                    selectedID: selection.selectedID, actions: actions
                )
            }
        }
    }
}

private struct AccountRing: View {
    let state: AccountState
    let now: Date
    let name: String
    let selected: Bool
    let select: () -> Void

    private var window: CodexQuotaWindow? {
        guard let window = state.menuWindow,
              !(window.resetsAt.map { $0 <= now } ?? false) else { return nil }
        return window
    }

    private var value: String {
        guard let window else { return "—" }
        return (state.isStale(at: now) ? "~" : "") + String(format: "%.0f%%", window.usedPercent)
    }

    private var caption: String {
        if state.isLoggingIn { return "로그인 중" }
        if state.isRefreshing && state.snapshot == nil { return "조회 중" }
        guard let window else { return state.snapshot == nil ? "미확인" : "확인 필요" }
        let period: String
        switch window.windowDurationMins {
        case 10_080: period = "주간"
        case 300: period = "5시간"
        default: period = "사용률"
        }
        return period + (state.isStale(at: now) ? " · 이전 값" : "")
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: Theme.small) {
                ZStack {
                    Circle().stroke(Theme.panelTrack, lineWidth: Theme.ringStroke)
                    if let window, window.usedPercent > 0 {
                        let arc = Circle().trim(from: 0, to: min(window.usedPercent, 100) / 100)
                        let stale = state.isStale(at: now)
                        arc.stroke(Theme.usageColor(window.usedPercent).opacity(stale ? 0.4 : 1),
                                   style: StrokeStyle(lineWidth: Theme.ringStroke, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    ProviderMark(provider: state.profile.provider)
                        .frame(width: 28, height: 28)
                        .opacity(window == nil ? 0.55 : 1)
                }
                .frame(width: Theme.ringSize, height: Theme.ringSize)
                .padding(.vertical, Theme.compact)
                Text(value).font(Theme.ringValue).foregroundStyle(Theme.panelPrimary)
                Text(name).font(Theme.ringLabel).lineLimit(1)
                    .foregroundStyle(selected ? Theme.panelPrimary : Theme.panelSecondary)
                Text(caption).font(Theme.caption).foregroundStyle(Theme.panelSecondary).lineLimit(1)
            }
            .frame(width: Theme.accountButtonWidth)
            .padding(.vertical, Theme.compact)
            .menuSelection(selected)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(AccountRingButtonStyle())
        .help("\(state.profile.name) · \(state.profile.provider.displayName)\n\(caption) \(value)")
        .accessibilityLabel("\(name), \(state.profile.provider.displayName), \(caption), \(value)")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
        .accessibilityIdentifier("account-ring-\(state.id.uuidString)")
    }
}

private struct AccountRingButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(isFocused ? Theme.mint : .clear, lineWidth: 2)
                    .padding(1)
            }
    }
}
