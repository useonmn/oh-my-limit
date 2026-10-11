import Foundation
import Darwin

public enum AccountProvider: String, Codable, Sendable {
    case codex
    case antigravity
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .claude: "Claude"
        }
    }
}

public enum AccountAuthentication: String, Codable, Sendable {
    case local
    case oauth
}

public struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let homePath: String
    public let isManaged: Bool
    public let provider: AccountProvider
    public let authentication: AccountAuthentication
    public var oauthIdentity: CodexIdentity?

    public init(id: UUID = UUID(), name: String, homePath: String, isManaged: Bool,
                provider: AccountProvider = .codex, authentication: AccountAuthentication = .local,
                oauthIdentity: CodexIdentity? = nil) {
        self.id = id
        self.name = name
        self.homePath = homePath
        self.isManaged = isManaged
        self.provider = provider
        self.authentication = authentication
        self.oauthIdentity = oauthIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, homePath, isManaged, provider, authentication, oauthIdentity
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            homePath: try values.decode(String.self, forKey: .homePath),
            isManaged: try values.decode(Bool.self, forKey: .isManaged),
            provider: try values.decodeIfPresent(AccountProvider.self, forKey: .provider) ?? .codex,
            authentication: try values.decodeIfPresent(AccountAuthentication.self, forKey: .authentication) ?? .local,
            oauthIdentity: try values.decodeIfPresent(CodexIdentity.self, forKey: .oauthIdentity)
        )
    }

    public var homeURL: URL { URL(fileURLWithPath: homePath, isDirectory: true) }
}

public struct AccountStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private struct Document: Codable {
        let version: Int
        let accounts: [AccountProfile]
    }

    private var fileURL: URL { directory.appendingPathComponent("accounts.json") }

    public func load() throws -> [AccountProfile] {
        if FileManager.default.fileExists(atPath: directory.path) {
            try prepareDirectories()
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
        } catch {
            throw AccountStoreError.unreadableConfiguration
        }
        guard (1...3).contains(document.version) else { throw AccountStoreError.unreadableConfiguration }
        try validate(document.accounts)
        return document.accounts
    }

    public func save(_ profiles: [AccountProfile]) throws {
        try validate(profiles)
        try prepareDirectories()
        let data = try JSONEncoder().encode(Document(version: 3, accounts: profiles))
        try Self.writePrivate(data, to: fileURL)
    }

    private func prepareDirectories() throws {
        try Self.preparePrivateDirectory(directory)
        for name in ["snapshots", "profiles"] {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            try Self.preparePrivateDirectory(folder)
            if name == "profiles" {
                for child in try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey]
                ) where try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try Self.preparePrivateDirectory(child)
                }
            }
        }
    }

    static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func writePrivate(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func validate(_ profiles: [AccountProfile]) throws {
        let homes = profiles.map {
            $0.authentication == .oauth
                ? "oauth:\($0.id.uuidString)"
                : "\($0.provider.rawValue):\($0.homeURL.standardizedFileURL.resolvingSymlinksInPath().path)"
        }
        guard Set(homes).count == homes.count,
              Set(profiles.map(\.id)).count == profiles.count else {
            throw AccountStoreError.duplicateHome
        }
        guard profiles.filter({ $0.provider == .antigravity && $0.authentication == .local }).count <= 1 else {
            throw AccountStoreError.duplicateLocalProvider
        }
        guard profiles.allSatisfy({ $0.authentication != .oauth || !$0.isManaged }) else {
            throw AccountStoreError.unreadableConfiguration
        }
        guard profiles.allSatisfy({ $0.homePath.hasPrefix("/") && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AccountStoreError.invalidHome
        }
    }
}

public enum AccountStoreError: Error, LocalizedError {
    case duplicateHome
    case duplicateLocalProvider
    case invalidHome
    case unreadableConfiguration

    public var errorDescription: String? {
        switch self {
        case .duplicateHome: "이미 연결한 계정 폴더입니다."
        case .duplicateLocalProvider: "이 서비스의 로컬 계정은 이미 연결되어 있습니다."
        case .invalidHome: "계정 이름과 로컬 계정 폴더를 확인해 주세요."
        case .unreadableConfiguration: "계정 설정을 읽지 못했습니다. 기존 설정은 변경하지 않았습니다."
        }
    }
}
