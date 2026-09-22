import Foundation
import Darwin
import Security

struct AntigravityEndpoint: Sendable {
    let port: Int
    let csrf: String
    let source: UsageSource
}

enum AntigravityLocal {
    static let summaryMethod = "RetrieveUserQuotaSummary"
    static let legacyMethod = "GetUserStatus"
    private static let service = "/exa.language_server_pb.LanguageServerService/"

    static func fetch() async throws -> CodexUsageSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        let endpoints = try await discover()
        for endpoint in endpoints.prefix(4) {
            for scheme in ["https", "http"] {
                try Task.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw AntigravityClientError.timedOut }
                do { return try await fetch(endpoint: endpoint, scheme: scheme, timeout: min(2, remaining)) }
                catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                }
            }
        }
        throw AntigravityClientError.localUnavailable
    }

    static func fetch(endpoint: AntigravityEndpoint, scheme: String = "http", timeout: TimeInterval = 2) async throws -> CodexUsageSnapshot {
        let client = AntigravityLoopbackSession()
        defer { client.session.invalidateAndCancel() }
        let summary: Data
        do {
            summary = try await request(client, endpoint, scheme, summaryMethod, timeout)
        } catch AntigravityHTTPError.unavailable {
            let legacy = try await request(client, endpoint, scheme, legacyMethod, timeout)
            return try AntigravityParser.legacy(legacy, source: endpoint.source)
        }
        // Even an empty or partially malformed groups array is authoritative; no legacy overwrite.
        let snapshot = try AntigravityParser.summary(summary, source: endpoint.source)
        guard snapshot.windows.contains(where: \.usageKnown) else { return snapshot }
        do {
            let status = try await request(client, endpoint, scheme, legacyMethod, timeout)
            let identity = try AntigravityParser.legacy(status, source: endpoint.source).identity
            return CodexUsageSnapshot(
                identity: identity, windows: snapshot.windows, fetchedAt: snapshot.fetchedAt,
                source: snapshot.source
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Identity is optional metadata; never replace authoritative quotas with legacy data.
            return snapshot
        }
    }

    private static func request(_ client: AntigravityLoopbackSession, _ endpoint: AntigravityEndpoint,
                                _ scheme: String, _ method: String, _ timeout: TimeInterval) async throws -> Data {
        guard ["http", "https"].contains(scheme), (1...65535).contains(endpoint.port),
              !endpoint.csrf.contains(where: { $0.isNewline || $0 == "\r" }) else { throw AntigravityClientError.unsafeEndpoint }
        let url = URL(string: "\(scheme)://127.0.0.1:\(endpoint.port)\(service)\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.csrf.isEmpty { request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        request.httpBody = method == summaryMethod ? Data(#"{"forceRefresh":true}"#.utf8)
            : Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8)
        do {
            let (bytes, response) = try await client.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AntigravityClientError.malformedResponse }
            guard http.statusCode == 200 else {
                if [404, 405, 501].contains(http.statusCode) { throw AntigravityHTTPError.unavailable }
                throw AntigravityClientError.localUnavailable
            }
            guard response.expectedContentLength <= 1_048_576 else { throw AntigravityClientError.outputLimitExceeded }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw AntigravityClientError.outputLimitExceeded }
                data.append(byte)
            }
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (root["code"] as? Int == 12 || root["code"] as? String == "unimplemented") {
                throw AntigravityHTTPError.unavailable
            }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? AntigravityHTTPError { throw error }
            if let error = error as? AntigravityClientError { throw error }
            if (error as? URLError)?.code == .timedOut { throw AntigravityClientError.timedOut }
            throw AntigravityClientError.localUnavailable
        }
    }

    /// Only inspect argv after the kernel executable path and same-user ownership identify a candidate.
    /// The sysctl buffer includes the environment; parse argc arguments only and retain just CSRF.
    private static func discover() async throws -> [AntigravityEndpoint] {
        var pids = [Int32](repeating: 0, count: 16_384)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { throw AntigravityClientError.localUnavailable }
        let officialCLI = AntigravityClient.findExecutable()?.path
        var candidates: [(Int32, UsageSource, String)] = []
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            try Task.checkCancellation()
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid() else { continue }
            var pathBytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count)) > 0 else { continue }
            let path = String(decoding: pathBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let source = classify(path: path, officialCLI: officialCLI) else { continue }
            let token = source == .antigravityCLI ? "" : csrfToken(pid: pid)
            guard let token else { continue }
            candidates.append((pid, source, token))
        }
        candidates.sort { rank($0.1) < rank($1.1) }
        var endpoints: [AntigravityEndpoint] = []
        // Bounds both subprocess count and port probing in a machine with many open workspaces.
        for (pid, source, csrf) in candidates.prefix(4) {
            do {
                let data = try await AntigravityCommand.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], timeout: 1)
                // Recheck ownership/path after lsof to avoid trusting a recycled process identifier.
                var pathBytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                var info = proc_bsdinfo()
                guard proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count)) > 0,
                      classify(path: String(decoding: pathBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), officialCLI: officialCLI) == source,
                      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                      info.pbi_uid == getuid() else { continue }
                endpoints += ports(data).prefix(4).map { AntigravityEndpoint(port: $0, csrf: csrf, source: source) }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
            }
        }
        return endpoints
    }

    static func classify(path: String, officialCLI: String?) -> UsageSource? {
        if let officialCLI, path == officialCLI { return .antigravityCLI }
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("language_server") || name.hasPrefix("language-server") else { return nil }
        // Kernel executable paths, not argv substring matches (which unrelated programs can spoof).
        if lower.contains("/antigravity ide.app/contents/")
            || lower.contains("/extensions/antigravity/bin/") { return .antigravityIDE }
        if lower.contains("/antigravity.app/contents/") { return .antigravityApp }
        return nil
    }

    static func ports(_ data: Data) -> [Int] {
        let ports = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("n"), let colon = line.lastIndex(of: ":"),
                  let port = Int(line[line.index(after: colon)...]), (1...65535).contains(port) else { return nil }
            return port
        }
        return Set(ports).sorted()
    }

    static func rank(_ source: UsageSource) -> Int {
        switch source {
        case .antigravityApp: 0
        case .antigravityCLI: 1
        case .antigravityIDE: 2
        case .antigravityOAuth: 3
        case .codexOAuth: 4
        }
    }

    private static func csrfToken(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var index = 4
        while index < size && bytes[index] != 0 { index += 1 } // executable path
        while index < size && bytes[index] == 0 { index += 1 }
        var wantsToken = false
        for _ in 0..<argc {
            guard index < size else { return nil }
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            let argument = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            if wantsToken { return validToken(argument) }
            if argument == "--csrf_token" { wantsToken = true }
            if argument.hasPrefix("--csrf_token=") { return validToken(String(argument.dropFirst(13))) }
        }
        return nil
    }

    private static func validToken(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        return value
    }
}

private enum AntigravityHTTPError: Error { case unavailable }

/// No proxy, cookies, credential persistence or redirects. Trust exceptions cannot escape loopback.
final class AntigravityLoopbackSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" || host == "[::1]" }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard task.currentRequest?.url?.host.map(Self.isLoopback) == true else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.isLoopback(challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
