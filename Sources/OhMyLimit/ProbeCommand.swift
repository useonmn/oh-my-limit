import AppKit
import OhMyLimitCore

@MainActor
func runAntigravityProbe() {
    Task { @MainActor in
        do {
            let executable: URL?
            if let index = CommandLine.arguments.firstIndex(of: "--antigravity-cli"),
               index + 1 < CommandLine.arguments.count {
                executable = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            } else {
                executable = nil
            }
            let snapshot = try await AntigravityClient(executableURL: executable).fetchUsage()
            struct ProbeResult: Encodable {
                let plan: String?
                let windows: [CodexQuotaWindow]
                let fetchedAt: Date
                let source: UsageSource?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ProbeResult(
                plan: snapshot.identity.planType, windows: snapshot.windows, fetchedAt: snapshot.fetchedAt,
                source: snapshot.source
            ))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Antigravity: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
}
