import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct OAuthRenewalTests {
    @Test(.timeLimit(.minutes(1)), arguments: [AccountProvider.codex, .claude, .antigravity], [false, true])
    func cancellationDuringRealRenewalSavesRotatedToken(_ provider: AccountProvider, _ rejected: Bool) async throws {
        let server = try AntigravityOAuthHTTPFixture(sendHeaders: false)
        let port = try await server.start()
        let identityServer = try AntigravityLoopbackFixture { _ in
            AntigravityLoopbackFixture.response(#"{"id":"acct-1","email":"person@example.invalid"}"#)
        }
        let identityPort = try await identityServer.start()
        let transport: CodexOAuthClient.Transport = { input in
            var request = input
            let target = input.url?.path.contains("userinfo") == true ? identityPort : port
            request.url = URL(string: "http://127.0.0.1:\(target)/token")!
            return try await OAuthHTTPS.send(request)
        }
        let setup = try await RenewalSetup(provider: provider, rejected: rejected, transport: transport)
        var requests = server.requests.makeAsyncIterator()
        let task = Task { try await setup.fetch(false) }
        defer { task.cancel() }
        do {
            _ = try #require(await requests.next())
            task.cancel()
            await server.respond(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#)
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await setup.savedRefresh() == "new-refresh")
            #expect(setup.fetches.value == (rejected ? 1 : 0))
        } catch {
            await server.stop()
            await identityServer.stop()
            throw error
        }
        await server.stop()
        await identityServer.stop()
    }

    @Test(arguments: [AccountProvider.codex, .claude, .antigravity])
    func failedSaveRetainsRotationUntilAuthorizationWithoutAnotherRenewal(_ provider: AccountProvider) async throws {
        let security = OAuthFakeSecurity()
        let renewals = RenewalCounter()
        let transport: CodexOAuthClient.Transport = { request in
            if request.url?.path.contains("userinfo") == true {
                return oauthResponse(request, body: #"{"id":"acct-1","email":"person@example.invalid"}"#)
            }
            renewals.increment()
            security.requiresAuthorization = true
            return oauthResponse(request, body: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#)
        }
        let setup = try await RenewalSetup(provider: provider, security: security, transport: transport)
        do { _ = try await setup.fetch(false); Issue.record("Expected storage failure") }
        catch {
            #expect((error as? CodexOAuthError)?.needsKeychainAccess == true
                || (error as? ClaudeOAuthError)?.needsKeychainAccess == true
                || (error as? AntigravityOAuthError)?.needsKeychainAccess == true)
        }
        #expect(setup.fetches.value == 0)
        #expect(security.interactionAttempts == 0)
        security.grantsAuthorization = true
        _ = try await setup.fetch(true)
        #expect(try await setup.savedRefresh() == "new-refresh")
        #expect(renewals.value == 1)
        #expect(security.deleteCount == 0)
    }
}

private final class RenewalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct RenewalSetup: Sendable {
    let fetch: @Sendable (Bool) async throws -> CodexUsageSnapshot
    let savedRefresh: @Sendable () async throws -> String?
    let fetches = RenewalCounter()

    init(provider: AccountProvider, rejected: Bool = false, security: OAuthFakeSecurity = OAuthFakeSecurity(),
         transport: @escaping CodexOAuthClient.Transport) async throws {
        let now = Date(timeIntervalSince1970: 1_789_400_000)
        let expiry = now.addingTimeInterval(rejected ? 3600 : -1)
        let profile = AccountProfile(name: "Fixture", homePath: "/fixture", isManaged: false, provider: provider,
                                     authentication: .oauth,
                                     oauthIdentity: CodexIdentity(email: "person@example.invalid", accountID: "acct-1"))
        let count = fetches
        switch provider {
        case .codex:
            let old = CodexOAuthCredentials(accessToken: "old", refreshToken: "old-refresh", expiresAt: expiry,
                                           accountID: "acct-1", email: "person@example.invalid")
            let store = CodexOAuthKeychain(service: "fixture.renewal", security: security)
            try store.save(old, profileID: profile.id)
            let oauth = CodexOAuthClient(issuer: "https://issuer.invalid", clientID: "fixture", transport: transport)
            let direct = CodexDirectClient(keychain: store, authenticate: { _ in old }, renew: oauth.refresh,
                fetch: {
                    count.increment()
                    if $0.accessToken == "old" { throw CodexOAuthError.signInRequired }
                    return CodexUsageSnapshot(identity: $0.identity, windows: [])
                }, clock: { now })
            fetch = { try await direct.fetchUsage(profile: profile, allowKeychainInteraction: $0) }
            savedRefresh = { try store.load(profileID: profile.id)?.refreshToken }
        case .claude:
            let old = ClaudeOAuthCredentials(accessToken: "old", refreshToken: "old-refresh", expiresAt: expiry,
                                            accountID: "acct-1", email: "person@example.invalid")
            let store = ClaudeOAuthKeychain(service: "fixture.renewal", security: security)
            try store.save(old, profileID: profile.id)
            let oauth = ClaudeOAuthClient(transport: transport)
            let direct = ClaudeDirectClient(keychain: store, authenticate: { _ in old }, renew: oauth.refresh,
                fetch: {
                    count.increment()
                    if $0.accessToken == "old" { throw ClaudeClientError.unauthorized }
                    return CodexUsageSnapshot(identity: $0.identity, windows: [])
                }, clock: { now })
            fetch = { try await direct.fetchUsage(profile: profile, allowKeychainInteraction: $0) }
            savedRefresh = { try store.load(profileID: profile.id)?.refreshToken }
        case .antigravity:
            let old = AntigravityOAuthCredentials(accessToken: "old", refreshToken: "old-refresh", expiresAt: expiry,
                                                 accountID: "acct-1", email: "person@example.invalid")
            let store = AntigravityOAuthKeychain(service: "fixture.renewal", security: security)
            try await store.save(old, profileID: profile.id)
            let oauth = AntigravityOAuthClient(configuration: .init(clientID: "fixture", clientSecret: "fixture"),
                                               transport: transport)
            let direct = AntigravityDirectClient(keychain: store, authenticate: { _ in old }, renew: oauth.refresh,
                fetch: {
                    count.increment()
                    if $0.accessToken == "old" { throw AntigravityOAuthError.signInRequired }
                    return CodexUsageSnapshot(identity: $0.identity, windows: [])
                }, clock: { now })
            fetch = { try await direct.fetchUsage(profile: profile, allowKeychainInteraction: $0) }
            savedRefresh = { try await store.load(profileID: profile.id)?.refreshToken }
        }
    }
}
