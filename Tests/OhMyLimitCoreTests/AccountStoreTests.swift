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
        #expect(document["version"] as? Int == 3)
        #expect(profiles.first?["provider"] as? String == "antigravity")
    }

    @Test(arguments: [1, 2, 3])
    func supportedVersionsAlwaysSaveAsVersionThree(_ version: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Versions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("accounts.json")
        try Data("{\"version\":\(version),\"accounts\":[]}".utf8).write(to: file)
        let store = AccountStore(directory: root)
        try store.save(store.load())
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(document["version"] as? Int == 3)
    }

    @Test func versionFourIsRejectedWithoutChangingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VersionFour-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("accounts.json")
        let data = Data("{\"version\":4,\"accounts\":[]}".utf8)
        try data.write(to: file)
        do {
            _ = try AccountStore(directory: root).load()
            Issue.record("Version four must be rejected")
        } catch {
            guard case AccountStoreError.unreadableConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func loadAndSaveTightenExistingDirectoriesAndCreatePrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Permissions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots")
        let profiles = root.appendingPathComponent("profiles")
        let profile = profiles.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let folders = [root, snapshots, profiles, profile]
        let store = AccountStore(directory: root)
        let file = root.appendingPathComponent("accounts.json")
        try store.save([])
        #expect(try permissions(file) == 0o600)
        for folder in folders {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try store.load().isEmpty)
        #expect(try permissions(file) == 0o600)
        for folder in folders {
            #expect(try permissions(folder) == 0o700)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try store.save([])
        #expect(try permissions(file) == 0o600)
        for folder in folders { #expect(try permissions(folder) == 0o700) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                == ["accounts.json", "profiles", "snapshots"])
    }

    @Test func firstSaveCreatesPrivateDirectoryAndConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FirstSave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try AccountStore(directory: root).save([])
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(root.appendingPathComponent("accounts.json")) == 0o600)
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func legacyProfileKeepsCodexProviderAndHome() throws {
        let data = Data(#"""
        {"id":"0BEB83DB-D4FA-4D31-8A87-FE9425989C62","name":"Original","homePath":"/original/codex","isManaged":true}
        """#.utf8)

        let profile = try JSONDecoder().decode(AccountProfile.self, from: data)

        #expect(profile.provider == .codex)
        #expect(profile.homePath == "/original/codex")
        #expect(profile.isManaged)
        #expect(profile.visibleWindowIDs == nil)
    }

    @Test func visibleWindowSelectionSurvivesRoundTripSortedAndUnique() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Visible-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(directory: root)
        var profile = AccountProfile(name: "Antigravity", homePath: "/oauth", isManaged: false,
                                     provider: .antigravity, authentication: .oauth,
                                     visibleWindowIDs: ["gemini-weekly", "3p-5h", "gemini-weekly"])
        #expect(profile.visibleWindowIDs == ["3p-5h", "gemini-weekly"])
        profile.visibleWindowIDs = ["b", "a", "b"]
        #expect(profile.visibleWindowIDs == ["a", "b"])

        try store.save([profile])

        #expect(try store.load() == [profile])
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
