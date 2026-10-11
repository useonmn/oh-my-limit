import Foundation
import LocalAuthentication
import Security
import Testing
@testable import OhMyLimitCore

@Suite(.serialized) struct AntigravityOAuthKeychainTests {
    @Test(.timeLimit(.minutes(1)))
    func pendingPromptRejectsBackgroundAccessAndSerializesInteractiveCalls() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let attempted = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let first = Task {
            await securityOperation(interactive: true) {
                entered.continuation.yield(())
                #expect(release.wait(timeout: .now() + 5) == .success)
                finished.signal()
                return errSecSuccess
            }
        }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        let second = Task {
            await securityOperation(interactive: true, before: { attempted.continuation.yield(()) }) {
                // This call may enter only after the first operation returned.
                #expect(finished.wait(timeout: .now()) == .success)
                return errSecSuccess
            }
        }
        var attempts = attempted.stream.makeAsyncIterator()
        _ = await attempts.next()
        let background = await securityOperation(interactive: false) {
            Issue.record("Noninteractive operation entered while a prompt was pending")
            return errSecSuccess
        }
        #expect(background == errSecInteractionNotAllowed)
        release.signal()
        #expect(await first.value == errSecSuccess)
        #expect(await second.value == errSecSuccess)
        entered.continuation.finish()
        attempted.continuation.finish()
    }

    @Test(arguments: [AccountProvider.codex, .claude, .antigravity], [false, true])
    func everyProviderRejectsCorruptOrOversizedItems(_ provider: AccountProvider, _ oversized: Bool) async throws {
        let security = OAuthFakeSecurity()
        // Identical credential field names preserve installed JSON readability;
        // valid JSON with an oversized email must hit the size cap, not decoding.
        security.dataOverride = oversized ? try JSONEncoder().encode(CodexOAuthCredentials(
            accessToken: "access", refreshToken: "refresh", expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            accountID: "acct", email: String(repeating: "a", count: 65_536)
        )) : Data("not credentials".utf8)
        let id = UUID()
        switch provider {
        case .codex:
            #expect(throws: CodexOAuthError.invalidResponse) {
                try CodexOAuthKeychain(service: "fixture", security: security).load(profileID: id)
            }
        case .claude:
            #expect(throws: ClaudeOAuthError.invalidResponse) {
                try ClaudeOAuthKeychain(service: "fixture", security: security).load(profileID: id)
            }
        case .antigravity:
            await #expect(throws: AntigravityOAuthError.invalidResponse) {
                try await AntigravityOAuthKeychain(service: "fixture", security: security).load(profileID: id)
            }
        }
    }

    @Test func legacyInteractionFlagIsDisabledOnlyDuringOperationAndRestoredOnFailure() {
        var previous: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess)
        let context = LAContext()
        context.interactionNotAllowed = true
        for result in [errSecSuccess, errSecAuthFailed, errSecInteractionNotAllowed] {
            let status = OAuthSystemSecurity.perform([kSecUseAuthenticationContext as String: context]) {
                var allowed: DarwinBoolean = true
                #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
                #expect(!allowed.boolValue)
                return result
            }
            #expect(status == result)
            var restored: DarwinBoolean = false
            #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
            #expect(restored.boolValue == previous.boolValue)
        }
    }

    @Test func loginAllowsCredentialInteractionButOrdinaryFetchDoesNot() async throws {
        let security = OAuthFakeSecurity()
        let google = oauthCredentials()
        let chatGPT = codexCredentials()
        let antigravity = AntigravityDirectClient(
            keychain: AntigravityOAuthKeychain(service: "fixture.oauth", security: security),
            authenticate: { _ in google }, renew: { $0 },
            fetch: { CodexUsageSnapshot(identity: $0.identity, windows: [], source: .antigravityOAuth) }
        )
        let codex = CodexDirectClient(
            keychain: CodexOAuthKeychain(service: "fixture.codex", security: security),
            authenticate: { _ in chatGPT }, renew: { $0 },
            fetch: { CodexUsageSnapshot(identity: $0.identity, windows: [], source: .codexOAuth) }
        )
        let id = UUID()
        _ = try await antigravity.login(profileID: id, onURL: { _ in })
        _ = try await codex.login(profileID: id, onURL: { _ in })
        // Each new login reads, attempts an update, then adds.
        #expect(security.interactionPolicies == Array(repeating: true, count: 6))
        security.requiresAuthorization = true
        let googleProfile = AccountProfile(id: id, name: "Google", homePath: "/local/oauth", isManaged: false,
                                          provider: .antigravity, authentication: .oauth, oauthIdentity: google.identity)
        let codexProfile = AccountProfile(id: id, name: "ChatGPT", homePath: "/local/oauth", isManaged: false,
                                         provider: .codex, authentication: .oauth, oauthIdentity: chatGPT.identity)
        await #expect(throws: AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed)) {
            try await antigravity.fetchUsage(profile: googleProfile)
        }
        await #expect(throws: CodexOAuthError.storageFailure(errSecInteractionNotAllowed)) {
            try await codex.fetchUsage(profile: codexProfile)
        }
        #expect(Array(security.interactionPolicies.suffix(2)) == [false, false])
        #expect(security.interactionAttempts == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func renewalKeepsInteractionScopedToTheRequest(_ expired: Bool, _ allowInteraction: Bool) async throws {
        let security = OAuthFakeSecurity()
        let googleKeychain = AntigravityOAuthKeychain(service: "test.renewal.google", security: security)
        let codexKeychain = CodexOAuthKeychain(service: "test.renewal.codex", security: security)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let expiry = now.addingTimeInterval(expired ? -1 : 3600)
        let google = AntigravityOAuthCredentials(accessToken: "old", refreshToken: "refresh", expiresAt: expiry,
                                                accountID: "google", email: "google@example.invalid")
        let codex = CodexOAuthCredentials(accessToken: "old", refreshToken: "refresh", expiresAt: expiry,
                                        accountID: "codex", email: "codex@example.invalid")
        let freshGoogle = AntigravityOAuthCredentials(accessToken: "new", refreshToken: "refresh",
                                                     expiresAt: now.addingTimeInterval(7200),
                                                     accountID: google.accountID, email: google.email)
        let freshCodex = CodexOAuthCredentials(accessToken: "new", refreshToken: "refresh",
                                             expiresAt: now.addingTimeInterval(7200),
                                             accountID: codex.accountID, email: codex.email)
        let id = UUID()
        try await googleKeychain.save(google, profileID: id)
        try codexKeychain.save(codex, profileID: id)
        let googleClient = AntigravityDirectClient(
            keychain: googleKeychain,
            authenticate: { _ in Issue.record("Unexpected OAuth"); throw AntigravityOAuthError.signInRequired },
            renew: { _ in freshGoogle },
            fetch: {
                if $0.accessToken == "old" { throw AntigravityOAuthError.signInRequired }
                return CodexUsageSnapshot(identity: $0.identity, windows: [])
            }, clock: { now }
        )
        let codexClient = CodexDirectClient(
            keychain: codexKeychain,
            authenticate: { _ in Issue.record("Unexpected OAuth"); throw CodexOAuthError.signInRequired },
            renew: { _ in freshCodex },
            fetch: {
                if $0.accessToken == "old" { throw CodexOAuthError.signInRequired }
                return CodexUsageSnapshot(identity: $0.identity, windows: [])
            }, clock: { now }
        )
        let googleProfile = AccountProfile(id: id, name: "Google", homePath: "/test", isManaged: false,
                                          provider: .antigravity, authentication: .oauth, oauthIdentity: google.identity)
        let codexProfile = AccountProfile(id: id, name: "Codex", homePath: "/test", isManaged: false,
                                         provider: .codex, authentication: .oauth, oauthIdentity: codex.identity)
        _ = try await googleClient.fetchUsage(profile: googleProfile, allowKeychainInteraction: allowInteraction)
        _ = try await codexClient.fetchUsage(profile: codexProfile, allowKeychainInteraction: allowInteraction)
        #expect(Array(security.interactionPolicies.suffix(4)) == Array(repeating: allowInteraction, count: 4))
        #expect(try await googleKeychain.load(profileID: id) == freshGoogle)
        #expect(try codexKeychain.load(profileID: id) == freshCodex)
        _ = try await googleClient.fetchUsage(profile: googleProfile)
        _ = try await codexClient.fetchUsage(profile: codexProfile)
        #expect(Array(security.interactionPolicies.suffix(2)) == [false, false])
        #expect(security.deleteCount == 0)
    }

    @Test func backgroundCredentialAccessNeverRequestsAuthorizationOrDeletesTokens() async throws {
        let security = OAuthFakeSecurity()
        let antigravity = AntigravityOAuthKeychain(service: "fixture.oauth", security: security)
        let codex = CodexOAuthKeychain(service: "fixture.codex", security: security)
        let id = UUID()
        let googleCredentials = oauthCredentials()
        let chatGPTCredentials = codexCredentials()
        try await antigravity.save(googleCredentials, profileID: id)
        try codex.save(chatGPTCredentials, profileID: id)
        security.requiresAuthorization = true

        await #expect(throws: AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed)) {
            try await antigravity.load(profileID: id)
        }
        await #expect(throws: AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed)) {
            try await antigravity.save(googleCredentials, profileID: id)
        }
        #expect(throws: CodexOAuthError.storageFailure(errSecInteractionNotAllowed)) {
            try codex.load(profileID: id)
        }
        #expect(throws: CodexOAuthError.storageFailure(errSecInteractionNotAllowed)) {
            try codex.save(chatGPTCredentials, profileID: id)
        }
        #expect(security.interactionAttempts == 0)
        #expect(security.deleteCount == 0)
        security.requiresAuthorization = false
        #expect(try await antigravity.load(profileID: id) == googleCredentials)
        #expect(try codex.load(profileID: id) == chatGPTCredentials)
    }

    @Test func accountsAndServicesStaySeparateAndUpdateWithoutDelete() async throws {
        let security = OAuthFakeSecurity()
        let store = AntigravityOAuthKeychain(service: "fixture.oauth", security: security)
        let other = AntigravityOAuthKeychain(service: "fixture.other", security: security)
        let a = UUID(), b = UUID()
        let first = oauthCredentials()
        let updated = AntigravityOAuthCredentials(accessToken: "updated", refreshToken: first.refreshToken, expiresAt: first.expiresAt, accountID: first.accountID, email: first.email)
        #expect(try await store.load(profileID: a) == nil)
        try await store.save(first, profileID: a)
        try await store.save(first, profileID: b)
        try await other.save(first, profileID: a)
        try await store.save(updated, profileID: a)
        #expect(try await store.load(profileID: a) == updated)
        #expect(try await store.load(profileID: b) == first)
        #expect(try await other.load(profileID: a) == first)
        #expect(security.deleteCount == 0)
        try await store.remove(profileID: a)
        try await store.remove(profileID: a)
        #expect(try await store.load(profileID: a) == nil)
        #expect(try await store.load(profileID: b) == first)
        #expect(try await other.load(profileID: a) == first)
    }

    @Test func invalidCredentialsAndSecurityFailuresDoNotFallBack() async throws {
        let security = OAuthFakeSecurity()
        let store = AntigravityOAuthKeychain(service: "fixture.oauth", security: security)
        let id = UUID()
        let invalid = AntigravityOAuthCredentials(accessToken: "", refreshToken: "r", expiresAt: Date(), accountID: "id", email: "person@example.invalid")
        await #expect(throws: AntigravityOAuthError.invalidResponse) { try await store.save(invalid, profileID: id) }
        security.status = errSecInteractionNotAllowed
        await #expect(throws: AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed)) { try await store.load(profileID: id) }
        await #expect(throws: AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed)) { try await store.save(oauthCredentials(), profileID: id) }
        await #expect(throws: AntigravityOAuthError.storageFailure(errSecInteractionNotAllowed)) { try await store.remove(profileID: id) }
        security.status = errSecSuccess
        security.corrupt = true
        await #expect(throws: AntigravityOAuthError.invalidResponse) { try await store.load(profileID: id) }
    }
}

private func securityOperation(interactive: Bool, before: @escaping @Sendable () -> Void = {},
                               operation: @escaping @Sendable () -> OSStatus) async -> OSStatus {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let context = LAContext()
            context.interactionNotAllowed = !interactive
            before()
            continuation.resume(returning: OAuthSystemSecurity.perform(
                [kSecUseAuthenticationContext as String: context], operation: operation
            ))
        }
    }
}

/// Models Security's add/update/not-found behavior without touching the user's Keychain.
final class OAuthFakeSecurity: AntigravityOAuthSecurity, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failure: OSStatus = errSecSuccess
    private var corrupted = false
    private var overriddenData: Data?
    private var deletes = 0
    private var authorizationRequired = false
    private var interactions = 0
    private var policies: [Bool] = []
    private var grants = false
    private var authorizedItems: Set<String> = []
    private var interactiveAccounts: [String] = []
    var grantsAuthorization: Bool {
        get { lock.withLock { grants } }
        set { lock.withLock { grants = newValue } }
    }
    var interactionAccounts: [String] { lock.withLock { interactiveAccounts } }
    var requiresAuthorization: Bool {
        get { lock.withLock { authorizationRequired } }
        set { lock.withLock { authorizationRequired = newValue } }
    }
    var interactionAttempts: Int { lock.withLock { interactions } }
    var interactionPolicies: [Bool] { lock.withLock { policies } }
    var status: OSStatus { get { lock.withLock { failure } } set { lock.withLock { failure = newValue } } }
    var corrupt: Bool { get { lock.withLock { corrupted } } set { lock.withLock { corrupted = newValue } } }
    var dataOverride: Data? { get { lock.withLock { overriddenData } } set { lock.withLock { overriddenData = newValue } } }
    var deleteCount: Int { lock.withLock { deletes } }

    private func authorizationStatus(_ query: [String: Any]) -> OSStatus {
        let interactionAllowed = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed != true
        policies.append(interactionAllowed)
        if interactionAllowed {
            interactiveAccounts.append(query[kSecAttrAccount as String] as! String)
        }
        let item = key(query)
        guard authorizationRequired, !authorizedItems.contains(item) else { return errSecSuccess }
        if !interactionAllowed {
            return errSecInteractionNotAllowed
        }
        interactions += 1
        if grants {
            authorizedItems.insert(item)
            return errSecSuccess
        }
        return errSecAuthFailed
    }

    private func key(_ query: [String: Any]) -> String {
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        #expect(service != nil)
        #expect(account.flatMap(UUID.init(uuidString:)) != nil)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        return "\(service!)|\(account!)"
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            let key = key(query)
            #expect(query[kSecReturnData as String] as? Bool == true)
            #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
            let authorization = authorizationStatus(query)
            if authorization != errSecSuccess { return (authorization, nil) }
            if failure != errSecSuccess { return (failure, nil) }
            if let overriddenData { return (errSecSuccess, overriddenData) }
            if corrupted { return (errSecSuccess, Data("not credentials".utf8)) }
            guard let data = items[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = key(attributes)
            #expect(attributes[kSecAttrAccessible as String] == nil)
            let authorization = authorizationStatus(attributes)
            if authorization != errSecSuccess { return authorization }
            if failure != errSecSuccess { return failure }
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = key(query)
            let authorization = authorizationStatus(query)
            if authorization != errSecSuccess { return authorization }
            if failure != errSecSuccess { return failure }
            guard items[key] != nil else { return errSecItemNotFound }
            items[key] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = key(query)
            deletes += 1
            let authorization = authorizationStatus(query)
            if authorization != errSecSuccess { return authorization }
            if failure != errSecSuccess { return failure }
            return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
