import Foundation
import LocalAuthentication
import Security

public struct AntigravityOAuthKeychain: Sendable {
    let store: OAuthKeychain<AntigravityOAuthCredentials>

    public init(service: String = "local.ohmylimit.antigravity.oauth") {
        store = OAuthKeychain(service: service, security: OAuthSystemSecurity())
    }

    init(service: String, security: any AntigravityOAuthSecurity) {
        store = OAuthKeychain(service: service, security: security)
    }

    public func load(profileID: UUID, allowInteraction: Bool = false) async throws -> AntigravityOAuthCredentials? {
        try await store.perform { try $0.load(profileID: profileID, allowInteraction: allowInteraction) }
    }

    public func save(_ credentials: AntigravityOAuthCredentials, profileID: UUID, allowInteraction: Bool = false) async throws {
        try await store.perform { try $0.save(credentials, profileID: profileID, allowInteraction: allowInteraction) }
    }

    public func remove(profileID: UUID, allowInteraction: Bool = false) async throws {
        try await store.perform { try $0.remove(profileID: profileID, allowInteraction: allowInteraction) }
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

    // The login Keychain ignores LAContext's per-query UI policy. The process
    // switch must therefore remain locked against interactive SecItem calls.
    // Background calls fail fast while ANY call owns it: they cannot wait on a
    // prompt, touch the switch during a prompt, or accidentally show their own.
    // Interactive calls serialize; the async direct flow dispatches blocking
    // Security work off the cooperative executor.
    static func perform(_ query: [String: Any], operation: () -> OSStatus) -> OSStatus {
        let noninteractive = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        if noninteractive {
            guard lock.try() else { return errSecInteractionNotAllowed }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        guard noninteractive else { return operation() }
        var previous: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return readStatus }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { return disableStatus }
        let status = operation()
        let restoreStatus = SecKeychainSetUserInteractionAllowed(previous.boolValue)
        return restoreStatus == errSecSuccess ? status : restoreStatus
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
