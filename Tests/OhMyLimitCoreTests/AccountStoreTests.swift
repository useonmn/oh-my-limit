import Foundation
import Testing
@testable import OhMyLimitCore

struct AccountStoreTests {
    @Test func antigravityProviderSurvivesConfigurationRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("accounts.json")
        let data = Data(#"""
        {"version":1,"accounts":[{"id":"0BEB83DB-D4FA-4D31-8A87-FE9425989C62","name":"Antigravity","homePath":"/local/user","isManaged":false,"provider":"antigravity"}]}
        """#.utf8)
        try data.write(to: file)
        let store = AccountStore(directory: root)

        try store.save(store.load())

        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let profiles = try #require(document["accounts"] as? [[String: Any]])
        #expect(profiles.first?["provider"] as? String == "antigravity")
    }

    @Test func legacyProfileKeepsCodexProviderAndHome() throws {
        let data = Data(#"""
        {"id":"0BEB83DB-D4FA-4D31-8A87-FE9425989C62","name":"Original","homePath":"/original/codex","isManaged":true}
        """#.utf8)

        let profile = try JSONDecoder().decode(AccountProfile.self, from: data)

        #expect(profile.provider == .codex)
        #expect(profile.homePath == "/original/codex")
        #expect(profile.isManaged)
    }

    @Test func multipleLocalAntigravityProfilesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        let first = AccountProfile(name: "Local", homePath: "/local/first", isManaged: false, provider: .antigravity)
        let second = AccountProfile(name: "Other", homePath: "/local/second", isManaged: false, provider: .antigravity)
        try store.save([first])

        #expect(throws: AccountStoreError.self) { try store.save([first, second]) }

        #expect(try store.load() == [first])
    }

    @Test func twoAccountsKeepDistinctHomesAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyLimit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = [
            AccountProfile(name: "개인 계정", homePath: "/profiles/personal home", isManaged: true),
            AccountProfile(name: "업무 계정", homePath: "/profiles/work home", isManaged: false),
        ]
        try AccountStore(directory: root).save(accounts)

        let restored = try AccountStore(directory: root).load()

        #expect(restored == accounts)
        #expect(restored.map(\.homePath) == accounts.map(\.homePath))
    }

    @Test func freshInstallationHasNoAccounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try AccountStore(directory: root).load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func duplicateAccountIsRejectedWithoutOverwritingAccounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        let first = AccountProfile(name: "계정 1", homePath: "/local/first", isManaged: false, provider: .antigravity)
        try store.save([first])
        let duplicate = AccountProfile(id: first.id, name: "중복 계정", homePath: root.path, isManaged: false,
                                       authentication: .oauth)

        #expect(throws: AccountStoreError.self) { try store.save([first, duplicate]) }
        #expect(try store.load() == [first])
    }

    @Test func corruptConfigurationIsNotSilentlyReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("invalid configuration".utf8)
        let file = root.appendingPathComponent("accounts.json")
        try data.write(to: file)

        #expect(throws: AccountStoreError.self) { try AccountStore(directory: root).load() }
        #expect(try Data(contentsOf: file) == data)
    }
}
