import Foundation
import Testing
@testable import OhMyLimitCore

@Suite struct AntigravityDirectClientTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func expiredCredentialsAreRenewedAndSavedBeforeQuotaFetch() async throws {
        let keychain = AntigravityOAuthKeychain(service: "fixture.direct", security: OAuthFakeSecurity())
        let id = UUID()
        let old = credentials(expiresAt: now)
        let fresh = credentials(expiresAt: now.addingTimeInterval(3600), token: "new")
        try await keychain.save(old, profileID: id)
        let clock = now
        let client = AntigravityDirectClient(
            keychain: keychain, authenticate: { _ in old },
            renew: { input in
                #expect(input == old)
                return fresh
            },
            fetch: { input in
                #expect(input == fresh)
                let saved = try await keychain.load(profileID: id)
                #expect(saved == fresh)
                return CodexUsageSnapshot(identity: input.identity, windows: [], source: .antigravityOAuth)
            }, clock: { clock }
        )

        let result = try await client.fetchUsage(profile: profile(id: id, identity: old.identity))

        #expect(result.identity == old.identity)
        #expect(try await keychain.load(profileID: id) == fresh)
    }

    @Test func absentOrMismatchedCredentialsNeverFetchAnotherAccount() async throws {
        let keychain = AntigravityOAuthKeychain(service: "fixture.direct", security: OAuthFakeSecurity())
        let id = UUID()
        let data = credentials(expiresAt: now.addingTimeInterval(3600))
        let client = AntigravityDirectClient(
            keychain: keychain, authenticate: { _ in data }, renew: { $0 },
            fetch: { _ in
                Issue.record("An unrelated account must not reach the quota endpoint")
                throw AntigravityOAuthError.quotaUnavailable
            }
        )
        let account = profile(id: id, identity: data.identity)
        await #expect(throws: AntigravityOAuthError.signInRequired) {
            try await client.fetchUsage(profile: account)
        }
        try await keychain.save(data, profileID: id)
        let other = profile(id: id, identity: CodexIdentity(email: "other@example.invalid", accountID: "other"))
        await #expect(throws: AntigravityOAuthError.signInRequired) {
            try await client.fetchUsage(profile: other)
        }
    }

    @Test func quotaDenialDoesNotDiscardSuccessfulLogin() async throws {
        let keychain = AntigravityOAuthKeychain(service: "fixture.direct", security: OAuthFakeSecurity())
        let id = UUID()
        let data = credentials(expiresAt: now.addingTimeInterval(3600))
        let clock = now
        let client = AntigravityDirectClient(
            keychain: keychain, authenticate: { _ in data }, renew: { $0 },
            fetch: { _ in throw AntigravityOAuthError.quotaUnavailable }, clock: { clock }
        )

        let identity = try await client.login(profileID: id, onURL: { _ in })
        await #expect(throws: AntigravityOAuthError.quotaUnavailable) {
            try await client.fetchUsage(profile: profile(id: id, identity: identity))
        }

        #expect(try await keychain.load(profileID: id) == data)
        try await client.disconnect(profileID: id)
        #expect(try await keychain.load(profileID: id) == nil)
    }

    private func credentials(expiresAt: Date, token: String = "access") -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(accessToken: token, refreshToken: "refresh", expiresAt: expiresAt,
                                   accountID: "google-id", email: "direct@example.invalid")
    }

    private func profile(id: UUID, identity: CodexIdentity) -> AccountProfile {
        AccountProfile(id: id, name: "Google", homePath: "/local/oauth", isManaged: false,
                       provider: .antigravity, authentication: .oauth, oauthIdentity: identity)
    }
}
