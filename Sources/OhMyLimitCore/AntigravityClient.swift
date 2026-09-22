import Foundation

public enum AntigravityClientError: Error, LocalizedError, Sendable, Equatable {
    case notFound, localUnavailable, unsupportedVersion, launchFailed, processFailed
    case timedOut, outputLimitExceeded, malformedResponse, unsafeEndpoint, cleanupFailed

    public var errorDescription: String? {
        switch self {
        case .notFound: "Antigravity를 실행해 로그인하거나 공식 agy CLI를 설치해 주세요."
        case .localUnavailable: "Antigravity 로컬 사용량 서버에 연결할 수 없습니다."
        case .unsupportedVersion: "사용량 조회에는 agy CLI 1.1.11 이상이 필요합니다. 업데이트해 주세요."
        case .launchFailed: "agy CLI를 시작할 수 없습니다. 설치와 실행 권한을 확인해 주세요."
        case .processFailed: "agy 사용량 조회에 실패했습니다. CLI의 로그인 상태를 확인해 주세요."
        case .timedOut: "Antigravity 응답 시간이 초과되었습니다. 다시 시도해 주세요."
        case .outputLimitExceeded: "Antigravity 응답이 허용된 크기를 초과했습니다."
        case .malformedResponse: "Antigravity 사용량 응답 형식을 확인할 수 없습니다."
        case .unsafeEndpoint: "Antigravity의 로컬 서버 주소를 확인할 수 없습니다."
        case .cleanupFailed: "Antigravity 조회용 임시 폴더를 정리하지 못했습니다."
        }
    }
}

/// Local quota RPC first; a version-gated, noninteractive official CLI report is the only fallback.
public struct AntigravityClient: Sendable {
    private let executableURL: URL?
    private let localFetch: @Sendable () async throws -> CodexUsageSnapshot

    public init(executableURL: URL? = nil) {
        self.init(executableURL: executableURL, localFetch: { try await AntigravityLocal.fetch() })
    }

    init(executableURL: URL?, localFetch: @escaping @Sendable () async throws -> CodexUsageSnapshot) {
        self.executableURL = executableURL
        self.localFetch = localFetch
    }

    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/agy" } + [
            "\(home)/.local/bin/agy", "\(home)/.antigravity/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"
        ]
        return candidates.first { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

    public func fetchUsage() async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        do { return try await localFetch() }
        catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
        }
        guard let executable = executableURL ?? Self.findExecutable() else { throw AntigravityClientError.notFound }
        let versionData = try await AntigravityCommand.run(executable: executable, arguments: ["--version"], timeout: 3)
        let version = String(decoding: versionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.supportsUsage(version) else { throw AntigravityClientError.unsupportedVersion }
        let report = try await AntigravityCommand.run(executable: executable,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "90s"], timeout: 90)
        return try AntigravityParser.cli(report)
    }

    static func supportsUsage(_ version: String) -> Bool {
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return false }
        let parts = version.split(separator: ".").compactMap { UInt($0) }
        return parts.count == 3 && (parts[0], parts[1], parts[2]) >= (1, 1, 11)
    }
}
