import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol OAuthFailure: Error {
    static var invalidResponse: Self { get }
    static var signInRequired: Self { get }
    static func storageFailure(_ status: Int32) -> Self
    var needsKeychainAccess: Bool { get }
}

extension CodexOAuthError: OAuthFailure {}
extension ClaudeOAuthError: OAuthFailure {}
extension AntigravityOAuthError: OAuthFailure {}

protocol OAuthCredentials: Codable, Sendable {
    associatedtype Failure: OAuthFailure
    var accountID: String { get }
    var expiresAt: Date { get }
    var identity: CodexIdentity { get }
    static func valid(_ credentials: Self) -> Bool
}

extension CodexOAuthCredentials: OAuthCredentials {
    typealias Failure = CodexOAuthError
    static func valid(_ credentials: Self) -> Bool { CodexOAuthClient.valid(credentials) }
}
extension ClaudeOAuthCredentials: OAuthCredentials {
    typealias Failure = ClaudeOAuthError
    static func valid(_ credentials: Self) -> Bool { ClaudeOAuthClient.valid(credentials) }
}
extension AntigravityOAuthCredentials: OAuthCredentials {
    typealias Failure = AntigravityOAuthError
    static func valid(_ credentials: Self) -> Bool { AntigravityOAuthClient.valid(credentials) }
}

/// Keeps the installed service/account keys and JSON encoding unchanged.
struct OAuthKeychain<Credentials: OAuthCredentials>: Sendable {
    let service: String
    let security: any AntigravityOAuthSecurity

    func load(profileID: UUID, allowInteraction: Bool) throws -> Credentials? {
        var query = query(profileID, allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Credentials.Failure.storageFailure(status) }
        guard let data, data.count <= 65_536,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              Credentials.valid(credentials) else { throw Credentials.Failure.invalidResponse }
        return credentials
    }

    func save(_ credentials: Credentials, profileID: UUID, allowInteraction: Bool) throws {
        guard Credentials.valid(credentials),
              let data = try? JSONEncoder().encode(credentials), data.count <= 65_536
        else { throw Credentials.Failure.invalidResponse }
        let query = query(profileID, allowInteraction: allowInteraction)
        let attributes = [kSecValueData as String: data]
        // Never delete the old item before updating it.
        var status = security.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            status = security.add(query.merging(attributes) { _, new in new })
            if status == errSecDuplicateItem { status = security.update(query, attributes: attributes) }
        }
        guard status == errSecSuccess else { throw Credentials.Failure.storageFailure(status) }
    }

    func remove(profileID: UUID, allowInteraction: Bool) throws {
        let status = security.delete(query(profileID, allowInteraction: allowInteraction))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Credentials.Failure.storageFailure(status)
        }
    }

    private func query(_ profileID: UUID, allowInteraction: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false,
            kSecUseAuthenticationContext as String: context
        ]
    }

    /// Blocking Security calls never occupy Swift's cooperative executor.
    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (Self) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation(self) })
            }
        }
    }
}

/// The monitor serializes operations per profile and drains cancellation before disconnect.
/// Actor isolation protects pending saves across different profiles, not network serialization.
actor OAuthDirectFlow<Credentials: OAuthCredentials> {
    private let keychain: OAuthKeychain<Credentials>
    private let authenticate: @Sendable (@escaping @Sendable (URL) -> Void) async throws -> Credentials
    private let renew: @Sendable (Credentials) async throws -> Credentials
    private let fetch: @Sendable (Credentials) async throws -> CodexUsageSnapshot
    private let isUnauthorized: @Sendable (any Error) -> Bool
    private let clock: @Sendable () -> Date
    private var pendingSaves: [UUID: Credentials] = [:]

    init(keychain: OAuthKeychain<Credentials>,
         authenticate: @escaping @Sendable (@escaping @Sendable (URL) -> Void) async throws -> Credentials,
         renew: @escaping @Sendable (Credentials) async throws -> Credentials,
         fetch: @escaping @Sendable (Credentials) async throws -> CodexUsageSnapshot,
         isUnauthorized: @escaping @Sendable (any Error) -> Bool,
         clock: @escaping @Sendable () -> Date) {
        self.keychain = keychain
        self.authenticate = authenticate
        self.renew = renew
        self.fetch = fetch
        self.isUnauthorized = isUnauthorized
        self.clock = clock
    }

    func login(profileID: UUID, onURL: @escaping @Sendable (URL) -> Void) async throws -> CodexIdentity {
        try Task.checkCancellation()
        let credentials = try await authenticate(onURL)
        try Task.checkCancellation()
        let previous = try await keychain.perform { try $0.load(profileID: profileID, allowInteraction: true) }
        try Task.checkCancellation()
        try await keychain.perform { try $0.save(credentials, profileID: profileID, allowInteraction: true) }
        if Task.isCancelled {
            try await keychain.perform {
                if let previous { try $0.save(previous, profileID: profileID, allowInteraction: true) }
                else { try $0.remove(profileID: profileID, allowInteraction: true) }
            }
            throw CancellationError()
        }
        pendingSaves[profileID] = nil
        return credentials.identity
    }

    func fetchUsage(profile: AccountProfile, allowKeychainInteraction: Bool) async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        guard let accountID = profile.oauthIdentity?.accountID else { throw Credentials.Failure.signInRequired }
        let loaded: Credentials?
        if let pending = pendingSaves[profile.id] {
            guard pending.accountID == accountID else { throw Credentials.Failure.signInRequired }
            // Retry storage, never reuse the invalidated refresh token or silently fetch
            // with credentials that were not durably saved. No disk fallback is permitted.
            try await saveRenewed(pending, profileID: profile.id, allowInteraction: allowKeychainInteraction)
            loaded = pending
        } else {
            loaded = try await keychain.perform {
                try $0.load(profileID: profile.id, allowInteraction: allowKeychainInteraction)
            }
        }
        guard var credentials = loaded, credentials.accountID == accountID else {
            throw Credentials.Failure.signInRequired
        }
        let needsRenewal = credentials.expiresAt <= clock().addingTimeInterval(60)
        if needsRenewal {
            credentials = try await renewAndSave(credentials, profile: profile, allowInteraction: allowKeychainInteraction)
        }
        try Task.checkCancellation()
        do { return try await fetch(credentials) }
        catch {
            guard !needsRenewal, isUnauthorized(error) else { throw error }
            credentials = try await renewAndSave(credentials, profile: profile, allowInteraction: allowKeychainInteraction)
            try Task.checkCancellation()
            return try await fetch(credentials)
        }
    }

    private func renewAndSave(_ credentials: Credentials, profile: AccountProfile,
                              allowInteraction: Bool) async throws -> Credentials {
        try Task.checkCancellation()
        // Unstructured task cancellation does not propagate from the caller. Await it
        // through parse AND save: quitting/cancelling cannot discard a rotated token.
        return try await Task {
            let renewed = try await renew(credentials)
            guard renewed.accountID == credentials.accountID else { throw Credentials.Failure.invalidResponse }
            pendingSaves[profile.id] = renewed
            try await saveRenewed(renewed, profileID: profile.id, allowInteraction: allowInteraction)
            return renewed
        }.value
    }

    private func saveRenewed(_ credentials: Credentials, profileID: UUID, allowInteraction: Bool) async throws {
        // On failure the typed storage error reaches the UI and the token stays only
        // in memory until authorization/retry succeeds. Process death cannot be made
        // durable while Keychain refuses writes; never spill credentials to a file.
        try await keychain.perform { try $0.save(credentials, profileID: profileID, allowInteraction: allowInteraction) }
        pendingSaves[profileID] = nil
    }

    func disconnect(profileID: UUID) async throws {
        try await keychain.perform { try $0.remove(profileID: profileID, allowInteraction: true) }
        pendingSaves[profileID] = nil
    }
}

enum OAuthPKCE {
    static func randomURLSafe(byteCount: Int = 32,
                              fill: (inout [UInt8]) -> OSStatus = {
                                  SecRandomCopyBytes(kSecRandomDefault, $0.count, &$0)
                              }) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard fill(&bytes) == errSecSuccess else { throw AntigravityOAuthError.callbackUnavailable }
        return base64URL(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A bounded, cookie-free, no-redirect session whose lifetime is one request.
final class OAuthHTTPS: NSObject, URLSessionTaskDelegate, Sendable {
    static func send(_ request: URLRequest, limit: Int = 65_536,
                     invalidResponse: any Error = AntigravityOAuthError.invalidResponse,
                     resourceTimeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = resourceTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: configuration, delegate: OAuthHTTPS(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= limit else {
            throw invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.handle(challenge, completionHandler)
    }

    private static func handle(_ challenge: URLAuthenticationChallenge,
                               _ completion: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completion(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
