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
        VStack(alignment: .leading, spacing: Theme.panelGap) {
            HStack(alignment: .top) {
                ProviderMark(provider: state.profile.provider)
                    .frame(width: Theme.detailProviderSize, height: Theme.detailProviderSize)
                    .padding(.vertical, Theme.panelSmall).padding(.trailing, Theme.panelSmall)
                    .padding(.top, Theme.panelSmall)
                VStack(alignment: .leading, spacing: Theme.panelSmall) {
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
                            .font(Theme.panelCaption).foregroundStyle(Theme.panelSecondary)
                            .lineLimit(1).help(snapshot.identity.email ?? "")
                    } else if let email = state.profile.oauthIdentity?.email {
                        Text(email).font(Theme.panelCaption).foregroundStyle(Theme.panelSecondary)
                            .lineLimit(1).help(email)
                    } else {
                        Text(accountDescription)
                            .font(Theme.panelCaption).foregroundStyle(Theme.panelSecondary)
                    }
                }
                Spacer(minLength: Theme.panelCompact)
                Menu {
                    Button("새로고침", action: refresh).disabled(state.isRefreshing || state.isLoggingIn)
                    Button(state.profile.provider == .antigravity && state.profile.authentication == .local
                           ? "Antigravity 열기" : "다시 로그인", action: login)
                        .disabled(state.isLoggingIn)
                    Divider()
                    Button("연결 해제", action: disconnect)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Theme.panelBody)
                        .frame(width: Theme.panelMenuSize, height: Theme.panelMenuSize)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .tint(.secondary)
                .fixedSize()
                .padding(.trailing, -(Theme.panelMenuSize - Theme.detailProviderSize) / 2)
                .help("계정 동작")
                .accessibilityLabel("\(state.profile.name) 계정 메뉴")
            }

            if state.isLoggingIn {
                HStack(spacing: Theme.panelCompact) {
                    ProgressView().controlSize(.small)
                    Text("브라우저에서 로그인을 완료해 주세요.")
                        .font(Theme.panelBody).fixedSize(horizontal: false, vertical: true)
                }
                Button("로그인 취소", action: cancel).buttonStyle(.borderless).controlSize(.small)
                    .foregroundStyle(Theme.link)
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
                    WarningLabel(text: "서버에서 기본 사용량이 제한된 상태입니다.", systemImage: "exclamationmark.circle.fill")
                }
                if let credits = snapshot.credits {
                    HStack {
                        Text("크레딧").foregroundStyle(Theme.panelSecondary)
                        Spacer()
                        Text(credits).monospacedDigit()
                    }
                    .font(Theme.panelCaption)
                }
            } else if state.isRefreshing {
                HStack(spacing: Theme.panelCompact) {
                    ProgressView().controlSize(.small)
                    Text("사용량을 확인하고 있습니다.").font(Theme.panelBody)
                }
                .padding(.vertical, Theme.panelCompact)
            } else {
                Text(state.profile.oauthIdentity == nil ? "아직 확인한 사용량이 없습니다." : "로그인됨 · 사용량 미확인")
                    .font(Theme.panelBody).foregroundStyle(Theme.panelSecondary)
                if state.profile.oauthIdentity != nil {
                    if !state.needsKeychainAccess {
                        Button("사용량 다시 확인", action: refresh)
                            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Theme.mint)
                    }
                } else {
                    Button(loginLabel, action: login)
                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Theme.link)
                }
            }

            if let error = state.error {
                WarningLabel(text: error)
            }
            if state.needsKeychainAccess && !state.isLoggingIn {
                Button("키체인 접근 허용", action: authorizeKeychain)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(state.isRefreshing)
                    .accessibilityLabel("\(state.profile.name) 키체인 접근 허용")
                Text("macOS 권한 창에서 ‘항상 허용’을 선택해 주세요. 기존 로그인은 유지됩니다.")
                    .font(Theme.panelCaption).foregroundStyle(Theme.panelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = state.snapshot {
                HStack(spacing: Theme.panelSmall) {
                    if state.isRefreshing { ProgressView().controlSize(.mini) }
                    Text("마지막 확인 · \(ageDescription(snapshot.fetchedAt))")
                    if state.isStale(at: now) {
                        Text("· 이전 값").foregroundStyle(Theme.panelPrimary)
                    }
                }
                .font(Theme.panelCaption)
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
    private var accountDescription: String {
        switch state.profile.provider {
        case .claude: "Claude 직접 로그인"
        case .antigravity: state.profile.authentication == .oauth ? "Google 직접 로그인" : "Antigravity 로컬 계정"
        case .codex: "ChatGPT 직접 로그인"
        }
    }

    private var loginLabel: String {
        switch state.profile.provider {
        case .claude: "Claude 로그인"
        case .antigravity: state.profile.authentication == .oauth ? "Google 로그인" : "Antigravity 열기 / 설치"
        case .codex: "ChatGPT 로그인"
        }
    }

}

struct PopoverActions {
    var selectAccount: (UUID) -> Void = { _ in }
    var refreshAll: () -> Void = {}
    var settings: () -> Void = {}
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
    private static let slotWidth = Theme.accountButtonWidth + Theme.panelCompact
    let accounts: [AccountState]
    let notice: String?
    let now: Date
    var preview = false
    var selectedID: UUID?
    var measuredHeight: CGFloat = Theme.panelMinimumHeight
    var actions = PopoverActions()
    @StateObject private var drag = RingDragState()

    private var selectedAccount: AccountState? {
        accounts.first { $0.id == selectedID } ?? accounts.first
    }

    /// Measure the selected detail only; the header and account selector stay fixed.
    static func height(
        for accounts: [AccountState], notice: String? = nil,
        now: Date = .now, preview: Bool = false, selectedID: UUID? = nil
    ) -> CGFloat {
        let view = PopoverView(accounts: accounts, notice: notice, now: now,
                               preview: preview, selectedID: selectedID)
        let host = NSHostingView(rootView: view.naturalLayout)
        return min(Theme.panelMaximumHeight, max(Theme.panelMinimumHeight, ceil(host.fittingSize.height)))
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
        .frame(width: Theme.width, height: measuredHeight)
        .foregroundStyle(Theme.panelPrimary)
        .tint(Theme.mint)
        .menuSurface()
    }

    private var header: some View {
        HStack(spacing: Theme.panelSmall) {
            Text("Oh My Limit").font(Theme.panelTitle).foregroundStyle(Theme.panelPrimary)
            if preview {
                Text("예시 데이터")
                    .font(Theme.panelCaption)
                    .padding(.horizontal, Theme.panelSmall + 1).padding(.vertical, 1)
                    .overlay { Capsule().stroke(Theme.panelSeparator, lineWidth: 0.5) }
            }
            Spacer(minLength: Theme.panelSmall)
            if !accounts.isEmpty {
                Button(action: actions.refreshAll) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: Theme.panelControlSize, height: Theme.panelControlSize)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .disabled(accounts.contains { $0.isRefreshing || $0.isLoggingIn })
                .help("새로고침 (⌘R)")
                .accessibilityLabel("모든 계정 새로고침")
            }
            Button(action: actions.addAccount) {
                Image(systemName: "plus")
                    .frame(width: Theme.panelControlSize, height: Theme.panelControlSize)
            }
            .help("계정 추가")
            .accessibilityLabel("계정 추가")
            Menu {
                Button("설정…", action: actions.settings).keyboardShortcut(",")
                Divider()
                Button("종료", action: actions.quit).keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: Theme.panelControlSize, height: Theme.panelControlSize)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()
            .help("설정 및 종료")
            .accessibilityLabel("설정 및 종료")
        }
        .buttonStyle(.borderless)
        .font(Theme.panelBody)
        .foregroundStyle(Theme.panelSecondary)
        .padding(.leading, Theme.panelTextInset)
        .padding(.trailing, Theme.opticalInset(control: Theme.panelControlSize, glyph: Theme.detailProviderSize))
        .frame(height: Theme.panelHeader)
    }

    private var accountSelector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.panelCompact) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, state in
                        let duplicateName = accounts.filter { $0.profile.name == state.profile.name }.count > 1
                        AccountRing(
                            state: state, now: now,
                            name: state.profile.name + (duplicateName ? " \(index + 1)" : ""),
                            selected: state.id == selectedAccount?.id,
                            select: { actions.selectAccount(state.id) }
                        )
                        .contextMenu {
                            Button("왼쪽으로 이동") { actions.moveAccount(state.id, index - 1) }
                                .disabled(index == 0)
                            Button("오른쪽으로 이동") { actions.moveAccount(state.id, index + 1) }
                                .disabled(index == accounts.count - 1)
                        }
                        .accessibilityAction(named: "왼쪽으로 이동") {
                            if index > 0 { actions.moveAccount(state.id, index - 1) }
                        }
                        .accessibilityAction(named: "오른쪽으로 이동") {
                            if index + 1 < accounts.count { actions.moveAccount(state.id, index + 1) }
                        }
                        .id(state.id)
                        .offset(x: drag.draggingID == state.id
                                ? drag.offset - CGFloat(index - drag.startIndex) * Self.slotWidth : 0)
                        .zIndex(drag.draggingID == state.id ? 1 : 0)
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
                .padding(.vertical, Theme.panelSmall)
            }
            .onAppear {
                if let id = selectedAccount?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedAccount?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: accounts.count > 3 ? Theme.scrollingSelectorHeight : Theme.selectorHeight)
    }

    private func content(scrolling: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.panelGap) {
            if let notice {
                HStack(alignment: .top, spacing: Theme.panelCompact) {
                    WarningLabel(text: notice)
                    Spacer(minLength: 0)
                    Button(action: actions.dismissNotice) {
                        Image(systemName: "xmark").frame(width: Theme.panelDismissSize, height: Theme.panelDismissSize)
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.panelSecondary).accessibilityLabel("알림 닫기")
                }
                .padding(.horizontal, Theme.panelPadding)
            }
            if accounts.isEmpty {
                emptyState
            } else {
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
                    .menuGroup(radius: Theme.panelGroupRadius)
                    .id(state.id)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("account-detail-\(state.id.uuidString)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.panelInset)
        .padding(.top, Theme.panelCompact)
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
        .padding(Theme.panelPadding)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.panelGap) {
            Text("Codex, Claude 또는 Antigravity를 연결해\n사용량과 초기화 시간을 확인하세요.")
                .font(Theme.panelBody).foregroundStyle(Theme.panelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("계정 연결…", action: actions.addAccount)
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, Theme.panelSmall)
        .padding(.horizontal, Theme.panelPadding)
    }
}

@MainActor
final class PopoverFlow: ObservableObject {
    @Published var showingSettings = false
    @Published var measuredHeight = Theme.panelMinimumHeight
    @Published var now = Date()
}

struct LivePopover: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var selection: AccountSelection
    @ObservedObject var flow: PopoverFlow
    let actions: PopoverActions
    let settingsView: AnyView

    var body: some View {
        Group {
            if flow.showingSettings {
                VStack(spacing: 0) {
                    HStack(spacing: Theme.small) {
                        Button(action: { flow.showingSettings = false }) {
                            Image(systemName: "chevron.left")
                                .frame(width: Theme.settingsControlSize, height: Theme.settingsControlSize)
                        }
                        .accessibilityLabel("뒤로")
                        Text("설정").font(Theme.settingsTitle)
                        Spacer(minLength: Theme.small)
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.settingsBody)
                    .foregroundStyle(Theme.panelSecondary)
                    .padding(.leading, Theme.opticalInset(control: Theme.settingsControlSize, glyph: Theme.panelSmall * 2))
                    .padding(.trailing, Theme.panelTextInset)
                    .frame(height: Theme.settingsHeaderHeight)
                    settingsView
                }
                .foregroundStyle(Theme.panelPrimary)
                .tint(Theme.mint)
                .menuSurface()
            } else {
                PopoverView(
                    accounts: monitor.accounts, notice: monitor.notice, now: flow.now,
                    selectedID: selection.selectedID, measuredHeight: flow.measuredHeight, actions: actions
                )
            }
        }
        .frame(width: flow.showingSettings ? Theme.settingsWidth : Theme.width,
               height: flow.measuredHeight)
    }
}

private struct AccountRing: View {
    let state: AccountState
    let now: Date
    let name: String
    let selected: Bool
    let select: () -> Void
    @FocusState private var focused: Bool

    private var window: CodexQuotaWindow? {
        guard let window = state.menuWindow,
              !window.hasExpired(at: now) else { return nil }
        return window
    }

    private var value: String {
        AccountUsageDisplay.value(for: state, at: now)
    }

    private var caption: String {
        if state.isLoggingIn { return "로그인 중" }
        if state.isRefreshing && state.snapshot == nil { return "조회 중" }
        guard let window else { return state.snapshot == nil ? "미확인" : "확인 필요" }
        let period: String
        if window.isWeekly {
            period = "주간"
        } else if window.windowDurationMins == 300 {
            period = "5시간"
        } else {
            period = "사용률"
        }
        return period + (state.isStale(at: now) ? " · 이전 값" : "")
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: Theme.panelSmall) {
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
                        .frame(width: Theme.ringProviderSize, height: Theme.ringProviderSize)
                        .opacity(window == nil ? 0.55 : 1)
                }
                .frame(width: Theme.ringSize, height: Theme.ringSize)
                .padding(.vertical, Theme.panelCompact)
                Text(value).font(Theme.ringValue).foregroundStyle(Theme.panelPrimary)
                Text(name).font(Theme.ringLabel).lineLimit(1)
                    .foregroundStyle(selected ? Theme.panelPrimary : Theme.panelSecondary)
                Text(caption).font(Theme.panelCaption).foregroundStyle(Theme.panelSecondary).lineLimit(1)
            }
            .frame(width: Theme.accountButtonWidth)
            .padding(.vertical, Theme.panelCompact)
            .menuSelection(selected)
            .contentShape(RoundedRectangle(cornerRadius: Theme.panelGroupRadius, style: .continuous))
        }
        .buttonStyle(AccountRingButtonStyle(focused: focused))
        .focused($focused)
        // The mint stroke below is the focus indicator; the system ring would double it.
        .focusEffectDisabled()
        .help("\(state.profile.name) · \(state.profile.provider.displayName)\n\(caption) \(value)")
        .accessibilityLabel("\(name), \(state.profile.provider.displayName), \(caption), \(value)")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
        .accessibilityIdentifier("account-ring-\(state.id.uuidString)")
    }
}

private struct AccountRingButtonStyle: ButtonStyle {
    // `@Environment(\.isFocused)` inside a ButtonStyle never reflects the
    // button's own keyboard focus, so the owning view passes it in.
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.panelGroupRadius - 1, style: .continuous)
                    .stroke(focused ? Theme.mint : .clear, lineWidth: 2)
                    .padding(1)
            }
    }
}
