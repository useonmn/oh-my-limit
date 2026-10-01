import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct CodexOAuthClientTests {
    @Test func authorizeURLUsesBrowserLoginParameters() throws {
        let redirect = URL(string: "http://localhost:1455/auth/callback")!
        let url = try #require(CodexOAuthClient.authorizeURL(
            issuer: "https://auth.openai.com", clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
            redirect: redirect, state: "state+&%", challenge: "challenge+&%"
        ))
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize?"))
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(query["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(query["code_challenge"] == "challenge+&%")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state+&%")
        #expect(query["scope"] == "openid profile email offline_access")
        #expect(query["id_token_add_organizations"] == "true")
        #expect(query["codex_cli_simplified_flow"] == "true")
        #expect(query["originator"] == "oh-my-limit")
    }

    @Test func usageRequestIdentifiesThisApp() async throws {
        let client = CodexRemoteClient(usageURL: "https://usage.invalid/wham/usage", transport: { request in
            #expect(request.value(forHTTPHeaderField: "originator") == "oh-my-limit")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OhMyLimit/") == true)
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
            return oauthResponse(request, body: #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}}}"#)
        })
        let snapshot = try await client.fetchUsage(codexCredentials())
        #expect(snapshot.windows.map(\.id) == ["codex.primary"])
    }

    @Test func pkceChallengeMatchesRFC7636Vector() {
        #expect(CodexOAuthClient.codeChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func credentialsParseIdentityFromIDToken() throws {
        let tokens = CodexOAuthClient.TokenResponse(
            access_token: "access+&%", refresh_token: "refresh+&%",
            id_token: codexJWT(email: "person@example.invalid", accountID: "acct-1", plan: "pro"),
            expires_in: 3600
        )
        let before = Date()
        let credentials = try CodexOAuthClient.credentials(from: tokens, previous: nil)
        #expect(credentials.accessToken == "access+&%")
        #expect(credentials.refreshToken == "refresh+&%")
        #expect(credentials.email == "person@example.invalid")
        #expect(credentials.accountID == "acct-1")
        #expect(credentials.planType == "pro")
        #expect(credentials.expiresAt >= before.addingTimeInterval(3599))
    }

    @Test func credentialsKeepPreviousIdentityAndRefreshTokenWhenOmitted() throws {
        let previous = codexCredentials()
        let tokens = CodexOAuthClient.TokenResponse(
            access_token: "renewed", refresh_token: nil, id_token: nil, expires_in: 120
        )
        let renewed = try CodexOAuthClient.credentials(from: tokens, previous: previous)
        #expect(renewed.refreshToken == previous.refreshToken)
        #expect(renewed.email == previous.email)
        #expect(renewed.accountID == previous.accountID)
        #expect(renewed.accessToken == "renewed")
    }

    @Test func credentialsRejectMissingIdentity() {
        let tokens = CodexOAuthClient.TokenResponse(
            access_token: "a", refresh_token: "r", id_token: nil, expires_in: 60
        )
        #expect(throws: CodexOAuthError.invalidResponse) {
            try CodexOAuthClient.credentials(from: tokens, previous: nil)
        }
    }

    @Test func refreshPostsFormGrantAndRotatesToken() async throws {
        let original = codexCredentials()
        let client = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "client+&%", transport: { request in
            #expect(request.url?.absoluteString == "https://issuer.invalid/oauth/token")
            #expect(request.httpMethod == "POST")
            let fields = oauthForm(request.httpBody!)
            #expect(fields["grant_type"] == "refresh_token")
            #expect(fields["client_id"] == "client+&%")
            #expect(fields["refresh_token"] == original.refreshToken)
            #expect(fields["code"] == nil)
            return oauthResponse(request, body: #"{"access_token":"renewed","refresh_token":"rotated","expires_in":120}"#)
        })
        let renewed = try await client.refresh(original)
        #expect(renewed.accessToken == "renewed")
        #expect(renewed.refreshToken == "rotated")
        #expect(renewed.email == original.email)
    }

    @Test func refreshMapsFailures() async throws {
        let client = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "c", transport: { request in
            oauthResponse(request, body: "{}", status: 500)
        })
        await #expect(throws: CodexOAuthError.authorizationFailed(500)) {
            try await client.refresh(codexCredentials())
        }
        let rejected = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "c", transport: { request in
            oauthResponse(request, body: "{}", status: 400)
        })
        await #expect(throws: CodexOAuthError.signInRequired) {
            try await rejected.refresh(codexCredentials())
        }
        let failure = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "c", transport: { _ in
            throw URLError(.cannotConnectToHost)
        })
        await #expect(throws: CodexOAuthError.networkFailure) {
            try await failure.refresh(codexCredentials())
        }
    }
}

@Suite struct CodexRemoteParserTests {
    @Test func usageMapsWindowsCreditsAndIdentity() throws {
        let body = """
        {"plan_type":"pro","account_id":"acct-9",
         "rate_limit":{"allowed":true,"limit_reached":false,
            "primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":60,"reset_at":1700000000},
            "secondary_window":{"used_percent":84,"limit_window_seconds":604800,"reset_after_seconds":60,"reset_at":1700100000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},
         "additional_rate_limits":[{"limit_name":"GPT-5.6","metered_feature":"codex_other",
            "rate_limit":{"allowed":true,"limit_reached":false,
            "primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_after_seconds":0,"reset_at":1700000100},
            "secondary_window":null}}]}
        """
        let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials())
        #expect(snapshot.source == .codexOAuth)
        #expect(snapshot.identity.email == codexCredentials().email)
        #expect(snapshot.identity.accountID == "acct-9")
        #expect(snapshot.identity.planType == "pro")
        #expect(snapshot.windows.count == 3)
        let primary = try #require(snapshot.windows.first { $0.id == "codex.primary" })
        #expect(primary.usedPercent == 42)
        #expect(primary.windowDurationMins == 300)
        #expect(primary.label == "5시간")
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        let secondary = try #require(snapshot.windows.first { $0.id == "codex.secondary" })
        #expect(secondary.windowDurationMins == 10_080)
        #expect(secondary.label == "주간")
        let extra = try #require(snapshot.windows.first { $0.id == "codex_other.primary" })
        #expect(extra.label == "GPT-5.6")
        #expect(snapshot.credits == "12.5")
        #expect(snapshot.ordinaryUsageAllowed == true)
    }

    @Test func usageRejectsEmptyPayload() {
        #expect(throws: CodexOAuthError.invalidResponse) {
            try CodexRemoteParser.usage(from: Data("{}".utf8), credentials: codexCredentials())
        }
    }
}

func codexCredentials() -> CodexOAuthCredentials {
    CodexOAuthCredentials(accessToken: "fixture-access", refreshToken: "fixture+&%refresh",
                          expiresAt: Date().addingTimeInterval(3600),
                          accountID: "acct-1", email: "person@example.invalid", planType: "pro")
}

func codexJWT(email: String, accountID: String, plan: String) -> String {
    func segment(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = segment(#"{"alg":"RS256","typ":"JWT"}"#)
    let payload = segment("""
        {"email":"\(email)","https://api.openai.com/auth":{"chatgpt_account_id":"\(accountID)","chatgpt_plan_type":"\(plan)"}}
        """)
    return "\(header).\(payload).signature"
}
