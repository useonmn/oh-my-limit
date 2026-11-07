import Foundation
import Security
import Testing
@testable import OhMyLimitCore

@Suite struct CodexOAuthClientTests {
    @Test(arguments: [Double?.none, 0, -1, .infinity, .nan, 31_536_001])
    func tokenLifetimeMustBePresentFiniteAndBounded(_ lifetime: Double?) {
        let tokens = CodexOAuthClient.TokenResponse(
            access_token: "a", refresh_token: "r", id_token: nil, expires_in: lifetime
        )
        #expect(throws: CodexOAuthError.invalidResponse) {
            try CodexOAuthClient.credentials(from: tokens, previous: codexCredentials())
        }
    }

    @Test func expiryUsesRequestStartAndRefreshCannotSwitchAccounts() throws {
        let issued = Date(timeIntervalSince1970: 1_789_400_000)
        let tokens = CodexOAuthClient.TokenResponse(
            access_token: "a", refresh_token: "r", id_token: nil, expires_in: 120
        )
        #expect(try CodexOAuthClient.credentials(from: tokens, previous: codexCredentials(),
                                                issuedAt: issued).expiresAt == issued.addingTimeInterval(120))
        let switched = CodexOAuthClient.TokenResponse(
            access_token: "a", refresh_token: "r",
            id_token: codexJWT(email: "other@example.invalid", accountID: "other", plan: "pro"), expires_in: 120
        )
        #expect(throws: CodexOAuthError.invalidResponse) {
            try CodexOAuthClient.credentials(from: switched, previous: codexCredentials(), issuedAt: issued)
        }
    }

    @Test func randomFailureNeverProducesPredictableState() {
        #expect(throws: AntigravityOAuthError.callbackUnavailable) {
            try OAuthPKCE.randomURLSafe(fill: { _ in errSecNotAvailable })
        }
    }

    @Test(.timeLimit(.minutes(1))) func browserDenialUsesCodexError() async throws {
        // Ephemeral port: the registered 1455/1457 may be held by a real Codex CLI login.
        let client = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "fixture", transport: { _ in
            Issue.record("Denied login must not exchange a code")
            throw CodexOAuthError.invalidResponse
        }, callbackPorts: [])
        let urls = AsyncStream<URL>.makeStream()
        let task = Task {
            defer { urls.continuation.finish() }
            return try await client.login { urls.continuation.yield($0) }
        }
        defer { task.cancel() }
        var iterator = urls.stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        let fields = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let redirect = try #require(fields.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:)))
        let state = try #require(fields.first { $0.name == "state" }?.value)
        _ = try await oauthRawRequest(redirect, fragments: [
            "GET /auth/callback?state=\(state)&error=access_denied HTTP/1.1\r\n\r\n"
        ])
        await #expect(throws: CodexOAuthError.userCancelled) { try await task.value }
    }

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

    @Test func usageForbiddenDoesNotRequestSignIn() async throws {
        for (status, expected) in [(401, CodexOAuthError.signInRequired), (403, .authorizationFailed(403))] {
            let client = CodexRemoteClient(usageURL: "https://usage.invalid/wham/usage", transport: { request in
                oauthResponse(request, body: "{}", status: status)
            })
            await #expect(throws: expected) {
                try await client.fetchUsage(codexCredentials())
            }
        }
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
        for status in [400, 401] {
            let rejected = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "c", transport: { request in
                oauthResponse(request, body: "{}", status: status)
            })
            await #expect(throws: CodexOAuthError.signInRequired) {
                try await rejected.refresh(codexCredentials())
            }
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
    @Test func extraIDsAreUniqueAndNeverMasqueradeAsMainQuota() throws {
        let body = """
        {"additional_rate_limits":[
          {"rate_limit":{"primary_window":{"used_percent":1}}},
          {"rate_limit":{"primary_window":{"used_percent":2}}},
          {"metered_feature":"codex","rate_limit":{"primary_window":{"used_percent":3}}},
          {"metered_feature":"codex","rate_limit":{"primary_window":{"used_percent":4}}}
        ]}
        """
        let windows = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials()).windows
        #expect(windows.count == 4)
        #expect(Set(windows.map(\.id)).count == 4)
        #expect(windows.allSatisfy { $0.id.hasPrefix("extra.") && !$0.id.hasPrefix("codex.") })
    }

    @Test(arguments: ["", #""used_percent":null,"#, #""used_percent":"bad","#,
                       #""used_percent":-1,"#, #""used_percent":true,"#])
    func missingOrInvalidUsageRemainsAnUnknownWeeklyWindow(_ field: String) throws {
        let body = """
        {"rate_limit":{"secondary_window":{\(field)"limit_window_seconds":604800}}}
        """
        let windows = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials()).windows
        #expect(windows.count == 1)
        #expect(windows[0].id == "codex.secondary")
        #expect(windows[0].windowDurationMins == 10_080)
        #expect(!windows[0].usageKnown)
        #expect(windows[0].usedPercent == 0)
    }

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
        #expect(snapshot.identity.accountID == "acct-1")
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
        let extra = try #require(snapshot.windows.first { $0.id == "extra.0.codex_other.primary" })
        #expect(extra.label == "GPT-5.6")
        #expect(snapshot.credits == "12.5")
        #expect(snapshot.ordinaryUsageAllowed == true)
    }

    @Test func usageRejectsEmptyPayload() {
        #expect(throws: CodexOAuthError.invalidResponse) {
            try CodexRemoteParser.usage(from: Data("{}".utf8), credentials: codexCredentials())
        }
    }

    @Test func spendCapOnlySeatRendersCreditWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = """
        {"plan_type":"enterprise","rate_limit":null,
         "spend_control":{"reached":false,"individual_limit":{"unit":"credits","limit":"200","used":50,
            "remaining":150,"used_percent":26,"reset_after_seconds":3600}}}
        """
        let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials(), now: now)
        #expect(snapshot.windows.map(\.id) == ["codex.spend-cap"])
        let cap = snapshot.windows[0]
        #expect(cap.label == "크레딧 한도")
        #expect(cap.usageKnown)
        #expect(cap.usedPercent == 25)
        #expect(cap.windowDurationMins == nil)
        #expect(cap.resetsAt == now.addingTimeInterval(3600))
        #expect(snapshot.ordinaryUsageAllowed == true)
    }

    @Test func reachedSpendCapIsExhaustedEvenWithoutPercent() throws {
        for individual in [#"{"remaining":0}"#, #"{"limit":100}"#] {
            let body = #"{"spend_control":{"reached":true,"individual_limit":\#(individual)}}"#
            let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials())
            #expect(snapshot.windows.map(\.usedPercent) == [100])
            #expect(snapshot.windows.map(\.usageKnown) == [true])
            #expect(snapshot.ordinaryUsageAllowed == false)
        }
    }

    @Test func spendCapBesidePlanWindowsKeepsPlanVerdictAndOrder() throws {
        let body = """
        {"rate_limit":{"allowed":true,"limit_reached":false,
            "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "spend_control":{"reached":true,"individual_limit":{"used":5,"limit":10}}}
        """
        let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials())
        #expect(snapshot.windows.map(\.id) == ["codex.secondary", "codex.spend-cap"])
        #expect(snapshot.windows[1].usedPercent == 50)
        #expect(snapshot.ordinaryUsageAllowed == true)
    }

    @Test(arguments: [(#"12.5"#, "12.5"), (#"40"#, "40"), (#""7.25""#, "7.25")])
    func creditBalanceAcceptsNumberOrString(_ balance: String, _ expected: String) throws {
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":\(balance)}}
        """
        let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials())
        #expect(snapshot.credits == expected)
    }

    @Test func resetTimeAcceptsMillisecondsAndFallsBackToResetAfter() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = """
        {"rate_limit":{
            "primary_window":{"used_percent":1,"limit_window_seconds":18000,"reset_at":1800000123000,"reset_after_seconds":5},
            "secondary_window":{"used_percent":2,"limit_window_seconds":604800,"reset_after_seconds":90}}}
        """
        let windows = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials(), now: now).windows
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_123))
        #expect(windows[1].resetsAt == now.addingTimeInterval(90))
    }

    @Test func absurdResetsAndSpendRatiosNeitherCrashNorRender() throws {
        let body = """
        {"rate_limit":{
            "primary_window":{"used_percent":1,"limit_window_seconds":18000,"reset_after_seconds":6e20},
            "secondary_window":{"used_percent":2,"limit_window_seconds":604800,"reset_at":6e23}},
         "spend_control":{"individual_limit":{"used":"1e300","limit":"1e-10"}}}
        """
        let windows = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials()).windows
        #expect(windows.map(\.resetsAt) == [nil, nil, nil])
        #expect(windows.map(\.usageKnown) == [true, true, false])
    }

    @Test func mainWindowLabelsComeFromDuration() throws {
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":10800},
                       "secondary_window":{"used_percent":2,"limit_window_seconds":"172800"}}}
        """
        let windows = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials()).windows
        #expect(windows.map(\.label) == ["3시간", "2일"])
        #expect(windows.map(\.windowDurationMins) == [180, 2_880])
        let unknown = #"{"rate_limit":{"primary_window":{"used_percent":1},"secondary_window":{"used_percent":2}}}"#
        let fallback = try CodexRemoteParser.usage(from: Data(unknown.utf8), credentials: codexCredentials()).windows
        #expect(fallback.map(\.label) == ["기본 한도", "보조 한도"])
    }

    @Test(arguments: [(#""allowed":true,"limit_reached":true,"#, false), (#""limit_reached":true,"#, false),
                      (#""allowed":false,"limit_reached":false,"#, false), (#""allowed":true,"#, true),
                      ("", nil)] as [(String, Bool?)])
    func limitReachedDeniesOrdinaryUsage(_ verdict: String, _ expected: Bool?) throws {
        let body = #"{"rate_limit":{\#(verdict)"primary_window":{"used_percent":100,"limit_window_seconds":18000}}}"#
        let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials())
        #expect(snapshot.ordinaryUsageAllowed == expected)
    }

    @Test func malformedSiblingsDegradeInsteadOfFailing() throws {
        let body = """
        {"rate_limit":{"allowed":"yes","primary_window":{},"secondary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_at":1.7e9}},
         "additional_rate_limits":["bad",{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":4}}}],
         "credits":"bad"}
        """
        let snapshot = try CodexRemoteParser.usage(from: Data(body.utf8), credentials: codexCredentials())
        #expect(snapshot.windows.map(\.id) == ["codex.secondary", "extra.1.unnamed.primary"])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.windows[1].label == "Spark")
        #expect(snapshot.ordinaryUsageAllowed == nil)
        #expect(snapshot.credits == nil)
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
