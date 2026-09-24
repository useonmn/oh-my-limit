import Foundation
import OhMyLimitCore
import Security

enum PreviewFixtures {
    static let now = Date(timeIntervalSince1970: 1_789_400_000)

    static func accounts(_ scenario: String) -> [AccountState] {
        guard scenario != "empty" && scenario != "missing-cli" else { return [] }
        let first = AccountProfile(name: "개인 계정", homePath: "/preview/personal", isManaged: true)
        let second = AccountProfile(name: "업무 계정", homePath: "/preview/work", isManaged: true)
        let personal = CodexUsageSnapshot(
            identity: CodexIdentity(email: "personal@example.com", planType: "plus"),
            windows: [
                CodexQuotaWindow(id: "codex.primary", label: "5시간", usedPercent: 34,
                    windowDurationMins: 300, resetsAt: now.addingTimeInterval(7_320)),
                CodexQuotaWindow(id: "codex.secondary", label: "주간", usedPercent: 62,
                    windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(280_800)),
            ], fetchedAt: now.addingTimeInterval(-30)
        )
        let work = CodexUsageSnapshot(
            identity: CodexIdentity(email: "work@example.com", planType: "pro"),
            windows: [
                CodexQuotaWindow(id: "codex.primary", label: "5시간", usedPercent: 18,
                    windowDurationMins: 300, resetsAt: now.addingTimeInterval(12_600)),
                CodexQuotaWindow(id: "codex.secondary", label: "주간", usedPercent: 86,
                    windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(162_000)),
            ], fetchedAt: now.addingTimeInterval(-45)
        )
        var states = [AccountState(profile: first, snapshot: personal), AccountState(profile: second, snapshot: work)]
        let antigravity = AccountProfile(
            name: "Antigravity", homePath: "/preview/local", isManaged: false, provider: .antigravity
        )
        let antigravityWindows = [
            CodexQuotaWindow(id: "gemini-5h", label: "Gemini", usedPercent: 23,
                windowDurationMins: 300, resetsAt: now.addingTimeInterval(7_800)),
            CodexQuotaWindow(id: "gemini-weekly", label: "Gemini", usedPercent: 48,
                windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(280_800)),
            CodexQuotaWindow(id: "claude-5h", label: "Claude + GPT", usedPercent: 76,
                windowDurationMins: 300, resetsAt: now.addingTimeInterval(4_200)),
            CodexQuotaWindow(id: "claude-weekly", label: "Claude + GPT", usedPercent: 91,
                windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(162_000)),
        ]
        let antigravitySnapshot = CodexUsageSnapshot(
            identity: CodexIdentity(email: "local@example.com", planType: "Google AI Pro"),
            windows: antigravityWindows, fetchedAt: now.addingTimeInterval(-240), source: .antigravityApp
        )
        switch scenario {
        case "keychain-antigravity", "keychain-codex", "keychain-cached":
            let provider: AccountProvider = scenario == "keychain-codex" ? .codex : .antigravity
            let identity = CodexIdentity(email: "personal@example.com", accountID: "preview-keychain")
            let profile = AccountProfile(
                name: provider.displayName, homePath: "/preview/oauth", isManaged: false,
                provider: provider, authentication: .oauth, oauthIdentity: identity
            )
            var state = AccountState(profile: profile, error: provider == .codex
                ? CodexOAuthError.storageFailure(errSecInteractionNotAllowed).localizedDescription
                : AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed).localizedDescription)
            state.needsKeychainAccess = true
            if scenario == "keychain-cached" {
                state.snapshot = CodexUsageSnapshot(
                    identity: identity, windows: antigravityWindows,
                    fetchedAt: now.addingTimeInterval(-900), source: .antigravityOAuth
                )
            }
            states = [state]
        case "codex-reserve":
            states = [AccountState(profile: second, snapshot: CodexUsageSnapshot(
                identity: work.identity,
                windows: [
                    CodexQuotaWindow(id: "base_model_inference.primary", label: "gpt-reserve",
                        usedPercent: 3, windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(3600)),
                    CodexQuotaWindow(id: "codex.primary", label: "주간",
                        usedPercent: 100, windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(162_000))
                ], fetchedAt: now
            ))]
        case "ring-boundaries":
            states = [0.0, 2, 100, 125, 34].enumerated().map { index, percent in
                let profile = AccountProfile(
                    name: "테스트 계정", homePath: "/preview/boundary/\(index)", isManaged: true
                )
                return AccountState(profile: profile, snapshot: CodexUsageSnapshot(
                    identity: CodexIdentity(email: "account-\(index + 1)@example.com"),
                    windows: [CodexQuotaWindow(
                        id: "codex.primary", label: "주간", usedPercent: percent,
                        windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(3600)
                    )], fetchedAt: now
                ), error: index == 4 ? "연결이 끊겨 마지막 확인값을 표시합니다." : nil)
            }
        case "many-windows":
            states = [AccountState(profile: first, snapshot: CodexUsageSnapshot(
                identity: personal.identity,
                windows: (1...10).map { index -> CodexQuotaWindow in
                    let id = index == 1 ? "codex.primary" : "model-\(index)"
                    return CodexQuotaWindow(id: id, label: "추가 모델 \(index)",
                        usedPercent: Double(index * 9), windowDurationMins: 300,
                        resetsAt: now.addingTimeInterval(Double(index * 3600)))
                }, fetchedAt: now
            ))]
        case "antigravity-oauth", "antigravity-oauth-login", "antigravity-oauth-denied", "antigravity-oauth-multiple":
            let identity = CodexIdentity(email: "google@example.com", planType: "Google AI Pro", accountID: "preview-google")
            let profile = AccountProfile(
                name: "Antigravity 개인", homePath: "/preview/oauth", isManaged: false,
                provider: .antigravity, authentication: .oauth,
                oauthIdentity: scenario == "antigravity-oauth-login" ? nil : identity
            )
            var state = AccountState(profile: profile)
            if scenario == "antigravity-oauth-login" {
                state.isLoggingIn = true
            } else if scenario == "antigravity-oauth-denied" {
                state.error = AntigravityOAuthError.quotaUnavailable.localizedDescription
            } else {
                state.snapshot = CodexUsageSnapshot(
                    identity: identity, windows: antigravityWindows, fetchedAt: now, source: .antigravityOAuth
                )
            }
            states = [state]
            if scenario == "antigravity-oauth-multiple" {
                let other = CodexIdentity(email: "work-google@example.com", accountID: "preview-google-work")
                states.append(AccountState(profile: AccountProfile(
                    name: "Antigravity 업무", homePath: "/preview/oauth", isManaged: false,
                    provider: .antigravity, authentication: .oauth, oauthIdentity: other
                ), snapshot: CodexUsageSnapshot(
                    identity: other, windows: [antigravityWindows[0]], fetchedAt: now, source: .antigravityOAuth
                )))
            }
        case "antigravity":
            states = [AccountState(profile: antigravity, snapshot: antigravitySnapshot)]
        case "antigravity-cli":
            states = [AccountState(profile: antigravity, snapshot: CodexUsageSnapshot(
                identity: CodexIdentity(), windows: antigravityWindows, fetchedAt: now, source: .antigravityCLI
            ))]
        case "antigravity-unknown":
            states = [AccountState(profile: antigravity, snapshot: CodexUsageSnapshot(
                identity: CodexIdentity(),
                windows: antigravityWindows.map {
                    CodexQuotaWindow(id: $0.id, label: $0.label, usedPercent: 0,
                        windowDurationMins: $0.windowDurationMins, resetsAt: nil,
                        usageKnown: false, resetDescription: "이 한도의 남은 양과 초기화 시각은 제공되지 않았습니다.")
                }, fetchedAt: now, source: .antigravityCLI
            ))]
        case "antigravity-error":
            states = [AccountState(profile: antigravity, error: "Antigravity를 실행해 로그인하거나 공식 agy CLI를 설치해 주세요.")]
        case "antigravity-loading":
            var loading = AccountState(profile: antigravity)
            loading.isRefreshing = true
            states = [loading]
        case "antigravity-stale":
            states = [AccountState(profile: antigravity, snapshot: CodexUsageSnapshot(
                identity: antigravitySnapshot.identity, windows: antigravityWindows,
                fetchedAt: now.addingTimeInterval(-900), source: .antigravityApp
            ), error: "로컬 사용량 서버에 연결하지 못했습니다. 마지막 확인값입니다.")]
        case "claude":
            states = [AccountState(profile: AccountProfile(
                name: "Claude", homePath: "/preview/claude", isManaged: false, provider: .claude
            ), snapshot: CodexUsageSnapshot(identity: CodexIdentity(planType: "max"), windows: [
                CodexQuotaWindow(id: "claude.session", label: "5시간", usedPercent: 27,
                    windowDurationMins: 300, resetsAt: now.addingTimeInterval(7_200)),
                CodexQuotaWindow(id: "claude.weekly", label: "주간", usedPercent: 53,
                    windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(260_000)),
                CodexQuotaWindow(id: "claude.model.Opus", label: "주간 · Opus", usedPercent: 75,
                    windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(260_000))
            ], fetchedAt: now, source: .claudeCode))]
        case "mixed":
            states.append(AccountState(profile: antigravity, snapshot: antigravitySnapshot))
        case "error":
            states[0].error = "Codex 응답 시간이 초과되었습니다. 마지막 확인값을 표시합니다."
            states[1].snapshot = nil
            states[1].error = "Codex 로그인이 필요합니다."
        case "loading":
            states[0].snapshot = nil
            states[0].isRefreshing = true
            states[1].snapshot = nil
            states[1].isLoggingIn = true
        case "models":
            states[0].snapshot = CodexUsageSnapshot(
                identity: CodexIdentity(email: "personal@example.com", planType: "pro"),
                windows: [
                    personal.windows[1],
                    CodexQuotaWindow(id: "spark:primary", label: "GPT-5.3-Codex-Spark", usedPercent: 0,
                        windowDurationMins: 300, resetsAt: now.addingTimeInterval(18_000)),
                    CodexQuotaWindow(id: "spark:secondary", label: "GPT-5.3-Codex-Spark", usedPercent: 0,
                        windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(604_800)),
                ], fetchedAt: now
            )
            states.removeLast()
        case "long":
            states[0].profile.name = "이름이 아주 긴 개인 개발용 Codex 구독 계정"
            states[0].snapshot = CodexUsageSnapshot(
                identity: CodexIdentity(email: "a-very-long-account-name-for-layout@example.com", planType: "plus"),
                windows: [
                    CodexQuotaWindow(id: "codex.primary", label: "주간", usedPercent: 100,
                        windowDurationMins: 10_080, resetsAt: now.addingTimeInterval(-1))
                ], fetchedAt: now.addingTimeInterval(-600)
            )
            states[1].snapshot = CodexUsageSnapshot(identity: CodexIdentity(), windows: [], fetchedAt: now)
        default: break
        }
        return states
    }
}
