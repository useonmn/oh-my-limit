import Foundation
import LocalAuthentication
import Security

public actor AntigravityOAuthKeychain {
    private let service: String
    private let security: any AntigravityOAuthSecurity

    public init(service: String = "local.ohmylimit.antigravity.oauth") {
        self.service = service
        self.security = OAuthSystemSecurity()
    }

    init(service: String, security: any AntigravityOAuthSecurity) {
        self.service = service
        self.security = security
    }

    public func load(profileID: UUID, allowInteraction: Bool = false) throws -> AntigravityOAuthCredentials? {
        var query = query(profileID, allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AntigravityOAuthError.storageFailure(status) }
        guard let data, data.count <= 65_536,
              let credentials = try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data),
              AntigravityOAuthClient.valid(credentials) else { throw AntigravityOAuthError.invalidResponse }
        return credentials
    }

    public func save(_ credentials: AntigravityOAuthCredentials, profileID: UUID, allowInteraction: Bool = false) throws {
        guard AntigravityOAuthClient.valid(credentials) else { throw AntigravityOAuthError.invalidResponse }
        let data: Data
        do { data = try JSONEncoder().encode(credentials) }
        catch { throw AntigravityOAuthError.invalidResponse }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let query = query(profileID, allowInteraction: allowInteraction)
        // Update in place: a failed save must not first destroy a working refresh token.
        var status = security.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            status = security.add(query.merging(attributes) { _, new in new })
            // Another instance may have added this same profile between update and add.
            if status == errSecDuplicateItem { status = security.update(query, attributes: attributes) }
        }
        guard status == errSecSuccess else { throw AntigravityOAuthError.storageFailure(status) }
    }

    public func remove(profileID: UUID, allowInteraction: Bool = false) throws {
        let status = security.delete(query(profileID, allowInteraction: allowInteraction))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AntigravityOAuthError.storageFailure(status) }
    }

    private func query(_ profileID: UUID, allowInteraction: Bool) -> [String: Any] {
        // This non-sandboxed macOS app uses the login Keychain.
        // Data Protection Keychain access requires a provisioned access group.
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
}

protocol AntigravityOAuthSecurity: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct OAuthSystemSecurity: AntigravityOAuthSecurity {
    private static let lock = NSLock()

    // The login Keychain ignores LAContext's per-query UI policy. Enforce it
    // with the legacy process-local switch, restoring it before releasing the
    // shared lock. All OAuth operations, including interactive login, use this
    // lock; no suspension, ACL changes, or system Keychain settings are involved.
    static func perform(_ query: [String: Any], operation: () -> OSStatus) -> OSStatus {
        lock.withLock {
            guard (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true else {
                return operation()
            }
            var previous: DarwinBoolean = false
            let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
            guard readStatus == errSecSuccess else { return readStatus }
            let disableStatus = SecKeychainSetUserInteractionAllowed(false)
            guard disableStatus == errSecSuccess else { return disableStatus }
            let status = operation()
            let restoreStatus = SecKeychainSetUserInteractionAllowed(previous.boolValue)
            return restoreStatus == errSecSuccess ? status : restoreStatus
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = Self.perform(query) { SecItemCopyMatching(query as CFDictionary, &result) }
        return (status, result as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        Self.perform(attributes) { SecItemAdd(attributes as CFDictionary, nil) }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        Self.perform(query) { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        Self.perform(query) { SecItemDelete(query as CFDictionary) }
    }
}
