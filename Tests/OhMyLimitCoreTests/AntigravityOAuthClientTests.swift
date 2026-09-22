import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityOAuthClientTests {
    private let config = AntigravityOAuthConfiguration(clientID: "native+&%", clientSecret: "fixture+&%")

    @Test func canonicalPKCEAndRandomState() throws {
        #expect(AntigravityOAuthClient.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try AntigravityOAuthClient.randomURLSafeToken()
        let second = try AntigravityOAuthClient.randomURLSafeToken()
        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func exchangeEncodesReservedCharactersAndBindsUserinfo() async throws {
        let client = AntigravityOAuthClient(configuration: config, transport: { request in
            if request.url?.path == "/token" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let fields = oauthForm(request.httpBody!)
                #expect(fields["client_id"] == "native+&%")
                #expect(fields["client_secret"] == "fixture+&%")
                #expect(fields["code"] == "code+&%")
                #expect(fields["code_verifier"] == "verifier+&%")
                #expect(fields["redirect_uri"] == "http://127.0.0.1:1234/callback")
                #expect(fields["grant_type"] == "authorization_code")
                return oauthResponse(request, body: #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer"}"#)
            }
            #expect(request.url?.absoluteString == "https://www.googleapis.com/oauth2/v2/userinfo")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            return oauthResponse(request, body: #"{"id":"google-123","email":"person@example.invalid"}"#)
        })
        let before = Date()
        let value = try await client.exchange(code: "code+&%", redirectURI: URL(string: "http://127.0.0.1:1234/callback")!, verifier: "verifier+&%")
        #expect(value.accountID == "google-123")
        #expect(value.email == "person@example.invalid")
        #expect(value.expiresAt >= before.addingTimeInterval(3599))
    }

    @Test func refreshPreservesRefreshTokenAndChecksIdentity() async throws {
        let original = oauthCredentials()
        let client = AntigravityOAuthClient(configuration: config, transport: { request in
            if request.url?.path == "/token" {
                let fields = oauthForm(request.httpBody!)
                #expect(fields["grant_type"] == "refresh_token")
                #expect(fields["refresh_token"] == original.refreshToken)
                #expect(fields["code"] == nil)
                return oauthResponse(request, body: #"{"access_token":"renewed","expires_in":120,"token_type":"Bearer"}"#)
            }
            return oauthResponse(request, body: #"{"id":"google-123","email":"new@example.invalid"}"#)
        })
        let renewed = try await client.refresh(original)
        #expect(renewed.refreshToken == original.refreshToken)
        #expect(renewed.accessToken == "renewed")
        #expect(renewed.email == "new@example.invalid")

        let wrongAccount = AntigravityOAuthClient(configuration: config, transport: { request in
            if request.url?.path == "/token" { return oauthResponse(request, body: #"{"access_token":"renewed","expires_in":120,"token_type":"Bearer"}"#) }
            return oauthResponse(request, body: #"{"id":"different","email":"other@example.invalid"}"#)
        })
        await #expect(throws: AntigravityOAuthError.invalidResponse) { try await wrongAccount.refresh(original) }
    }

    @Test(arguments: [
        #"{"access_token":"","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"bad\r\nheader","refresh_token":"r","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":0,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":-1,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":true,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":999999999,"token_type":"Bearer"}"#,
        #"{"access_token":"a","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"a","refresh_token":"r","expires_in":3600,"token_type":"MAC"}"#
    ]) func malformedTokensAreRejected(body: String) async {
        let client = AntigravityOAuthClient(configuration: config, transport: { oauthResponse($0, body: body) })
        await #expect(throws: AntigravityOAuthError.invalidResponse) {
            try await client.exchange(code: "c", redirectURI: URL(string: "http://127.0.0.1:1234/callback")!, verifier: "v")
        }
    }

    @Test(arguments: [#"{"id":"","email":"person@example.invalid"}"#, #"{"id":"google-123","email":""}"#, #"{"id":123,"email":"person@example.invalid"}"#])
    func malformedUserinfoIsRejected(body: String) async {
        let client = AntigravityOAuthClient(configuration: config, transport: { request in
            if request.url?.path == "/token" { return oauthResponse(request, body: #"{"access_token":"a","expires_in":3600,"token_type":"Bearer"}"#) }
            return oauthResponse(request, body: body)
        })
        await #expect(throws: AntigravityOAuthError.invalidResponse) { try await client.refresh(oauthCredentials()) }
    }

    @Test func statusSizeAndTransportErrorsAreSanitized() async {
        for status in [301, 400, 401, 429, 500] {
            let client = AntigravityOAuthClient(configuration: config, transport: { oauthResponse($0, body: "sensitive body", status: status) })
            await #expect(throws: AntigravityOAuthError.authorizationFailed(status)) { try await client.refresh(oauthCredentials()) }
        }
        let large = AntigravityOAuthClient(configuration: config, transport: { oauthResponse($0, body: String(repeating: "x", count: 65_537)) })
        await #expect(throws: AntigravityOAuthError.invalidResponse) { try await large.refresh(oauthCredentials()) }
        let timeout = AntigravityOAuthClient(configuration: config, transport: { _ in throw URLError(.timedOut) })
        await #expect(throws: AntigravityOAuthError.timedOut) { try await timeout.refresh(oauthCredentials()) }
        let failure = AntigravityOAuthClient(configuration: config, transport: { _ in throw URLError(.cannotConnectToHost) })
        await #expect(throws: AntigravityOAuthError.networkFailure) { try await failure.refresh(oauthCredentials()) }
        let cancelled = AntigravityOAuthClient(configuration: config, transport: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.refresh(oauthCredentials()) }
    }
}

func oauthCredentials() -> AntigravityOAuthCredentials {
    AntigravityOAuthCredentials(accessToken: "fixture-access", refreshToken: "fixture+&%refresh", expiresAt: Date().addingTimeInterval(3600), accountID: "google-123", email: "person@example.invalid")
}

func oauthResponse(_ request: URLRequest, body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
}

func oauthForm(_ data: Data) -> [String: String] {
    Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self).split(separator: "&").map {
        let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!, String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!)
    })
}
