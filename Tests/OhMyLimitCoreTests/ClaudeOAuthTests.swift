import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct ClaudeOAuthTests {
    @Test func authorizeURLRequestsOnlyUsageReadScope() throws {
        let redirect = URL(string: "http://localhost:53682/callback")!
        let url = try #require(ClaudeOAuthClient.authorizeURL(redirect: redirect, state: "state+&%", challenge: "challenge"))
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?"))
        #expect(query["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(query["scope"] == "user:profile")
        #expect(query["response_type"] == "code")
        #expect(query["code"] == "true")
        #expect(query["redirect_uri"] == "http://localhost:53682/callback")
        #expect(query["code_challenge"] == "challenge")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state+&%")
    }

    @Test func refreshSendsOwnRefreshTokenAndStoresTheRotatedOne() async throws {
        let requests = RequestLog()
        let client = ClaudeOAuthClient(transport: { request in
            requests.append(request)
            let body = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"account":{"uuid":"acct-1","email_address":"person@example.invalid"}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let before = Date()
        let renewed = try await client.refresh(claudeCredentials())
        let request = try #require(requests.all.first)
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["grant_type": "refresh_token", "refresh_token": "fixture-refresh",
                         "client_id": ClaudeOAuthConfiguration.clientID, "scope": "user:profile"])
        #expect(renewed.accessToken == "new-access")
        #expect(renewed.refreshToken == "new-refresh")
        #expect(renewed.expiresAt >= before.addingTimeInterval(28_799))
    }

    @Test func rejectedRefreshTokenRequiresSignIn() async {
        let client = ClaudeOAuthClient(transport: { request in
            (Data(#"{"error":"invalid_grant"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: ClaudeOAuthError.signInRequired) { try await client.refresh(claudeCredentials()) }
    }

    @Test func tokenResponsesKeepIdentityAndNeverSwitchAccounts() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_789_400_000)
        let previous = claudeCredentials()
        let omitted = ClaudeOAuthClient.TokenResponse(access_token: "renewed", refresh_token: nil, expires_in: 3600, account: nil)
        let renewed = try ClaudeOAuthClient.credentials(from: omitted, previous: previous, issuedAt: issuedAt)
        #expect(renewed.refreshToken == previous.refreshToken)
        #expect(renewed.accountID == previous.accountID)
        #expect(renewed.email == previous.email)
        #expect(renewed.expiresAt == issuedAt.addingTimeInterval(3600))
        let other = ClaudeOAuthClient.TokenResponse(
            access_token: "renewed", refresh_token: "r", expires_in: 3600,
            account: .init(uuid: "acct-2", email_address: "other@example.invalid")
        )
        #expect(throws: ClaudeOAuthError.invalidResponse) {
            try ClaudeOAuthClient.credentials(from: other, previous: previous, issuedAt: issuedAt)
        }
        #expect(throws: ClaudeOAuthError.invalidResponse) {
            try ClaudeOAuthClient.credentials(from: omitted, previous: nil, issuedAt: issuedAt)
        }
    }

    @Test func expiredTokenIsRenewedAndSavedBeforeFetching() async throws {
        let now = Date(timeIntervalSince1970: 1_789_400_000)
        let keychain = ClaudeOAuthKeychain(service: "fixture.claude.direct", security: OAuthFakeSecurity())
        let profile = claudeProfile()
        let expired = claudeCredentials(expiresAt: now.addingTimeInterval(-10))
        try keychain.save(expired, profileID: profile.id)
        let renewed = claudeCredentials(access: "renewed-access", refresh: "renewed-refresh",
                                        expiresAt: now.addingTimeInterval(28_800))
        let direct = ClaudeDirectClient(
            keychain: keychain, authenticate: { _ in expired }, renew: { _ in renewed },
            fetch: { credentials in
                #expect(credentials.accessToken == "renewed-access")
                return CodexUsageSnapshot(identity: credentials.identity, windows: [], source: .claudeOAuth)
            },
            clock: { now }
        )
        let snapshot = try await direct.fetchUsage(profile: profile)
        #expect(snapshot.identity.accountID == "acct-1")
        #expect(try keychain.load(profileID: profile.id) == renewed)
    }

    @Test func serverRejectedTokenIsRenewedOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_789_400_000)
        let keychain = ClaudeOAuthKeychain(service: "fixture.claude.direct", security: OAuthFakeSecurity())
        let profile = claudeProfile()
        try keychain.save(claudeCredentials(expiresAt: now.addingTimeInterval(3600)), profileID: profile.id)
        let renewals = Counter()
        let direct = ClaudeDirectClient(
            keychain: keychain, authenticate: { _ in claudeCredentials() },
            renew: { _ in
                renewals.increment()
                return claudeCredentials(access: "renewed-access", expiresAt: now.addingTimeInterval(7200))
            },
            fetch: { credentials in
                guard credentials.accessToken == "renewed-access" else { throw ClaudeClientError.unauthorized }
                return CodexUsageSnapshot(identity: credentials.identity, windows: [], source: .claudeOAuth)
            },
            clock: { now }
        )
        _ = try await direct.fetchUsage(profile: profile)
        #expect(renewals.value == 1)
        #expect(try keychain.load(profileID: profile.id)?.accessToken == "renewed-access")
    }

    @Test @MainActor func directClaudeAccountsStaySeparateAndSurviveRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeOAuth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = ClaudeOAuthKeychain(service: "fixture.claude.monitor", security: OAuthFakeSecurity())
        let credentials = claudeCredentials()
        let usage = try ClaudeUsageParser.parse(
            Data(#"{"seven_day":{"utilization":41}}"#.utf8), identity: credentials.identity, source: .claudeOAuth
        )
        let direct = ClaudeDirectClient(keychain: keychain, authenticate: { _ in credentials },
                                        renew: { $0 }, fetch: { _ in usage })
        let monitor = UsageMonitor(
            store: AccountStore(directory: root.appendingPathComponent("app")), directClaude: direct
        )
        let other = try #require(monitor.createClaudeAccount(name: "Other"))
        let id = try #require(monitor.createClaudeAccount())
        #expect(other != id)

        await monitor.login(id, onURL: { _ in })?.value

        let state = try #require(monitor.accounts.first { $0.id == id })
        #expect(state.profile.authentication == .oauth)
        #expect(state.profile.oauthIdentity == credentials.identity)
        #expect(state.snapshot == usage)
        #expect(state.menuWindow?.usedPercent == 41)
        #expect(try keychain.load(profileID: id) == credentials)
        let restored = UsageMonitor(store: monitor.store, directClaude: direct)
        #expect(restored.accounts.map(\.profile.authentication) == [.oauth, .oauth])
        #expect(restored.accounts[0].snapshot == nil)
        #expect(restored.accounts[1].snapshot == usage)

        await monitor.disconnect(id)?.value
        #expect(monitor.accounts.map(\.id) == [other])
        #expect(try keychain.load(profileID: id) == nil)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var all: [URLRequest] { lock.withLock { requests } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private func claudeProfile() -> AccountProfile {
    AccountProfile(name: "Claude", homePath: "/tmp/oauth", isManaged: false, provider: .claude,
                   authentication: .oauth, oauthIdentity: claudeCredentials().identity)
}

func claudeCredentials(access: String = "fixture-access", refresh: String = "fixture-refresh",
                       expiresAt: Date = Date().addingTimeInterval(3600)) -> ClaudeOAuthCredentials {
    ClaudeOAuthCredentials(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                           accountID: "acct-1", email: "person@example.invalid")
}
