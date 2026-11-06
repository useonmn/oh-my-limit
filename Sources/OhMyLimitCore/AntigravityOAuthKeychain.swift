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
    private static let gate = Gate()

    // The login Keychain ignores LAContext's per-query UI policy. The process
    // switch must therefore remain locked against interactive SecItem calls.
    // Background calls fail fast while an interactive call owns or awaits it:
    // they cannot wait on a prompt, touch the switch during a prompt, or
    // accidentally show their own. Background calls only wait behind other
    // (short) background calls. Interactive calls serialize with everything;
    // the async direct flow dispatches blocking Security work off the
    // cooperative executor.
    static func perform(_ query: [String: Any], operation: () -> OSStatus) -> OSStatus {
        let noninteractive = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        guard gate.acquire(interactive: !noninteractive) else { return errSecInteractionNotAllowed }
        defer { gate.release() }
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

    /// Single-holder admission. The condition lock is never held while the
    /// Security operation runs.
    private final class Gate: @unchecked Sendable {
        private enum Holder { case none, background, interactive }
        private let condition = NSCondition()
        private var holder = Holder.none
        private var interactiveWaiting = 0

        /// Returns false only for a background call facing an interactive one.
        func acquire(interactive: Bool) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            if interactive {
                interactiveWaiting += 1
                while holder != .none { condition.wait() }
                interactiveWaiting -= 1
                holder = .interactive
                return true
            }
            while true {
                if holder == .interactive || interactiveWaiting > 0 { return false }
                if holder == .none { break }
                condition.wait()
            }
            holder = .background
            return true
        }

        func release() {
            condition.lock()
            holder = .none
            condition.broadcast()
            condition.unlock()
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
