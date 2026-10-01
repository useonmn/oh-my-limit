import Combine
import Foundation

public struct AccountState: Identifiable, Sendable {
    public var profile: AccountProfile
    public var snapshot: CodexUsageSnapshot?
    public var isRefreshing = false
    public var isLoggingIn = false
    public var needsKeychainAccess = false
    public var error: String?
    public var id: UUID { profile.id }

    public init(profile: AccountProfile, snapshot: CodexUsageSnapshot? = nil, error: String? = nil) {
        self.profile = profile
        self.snapshot = snapshot
        self.error = error
    }

    public func isStale(at now: Date) -> Bool {
        guard let snapshot else { return false }
        let threshold: TimeInterval = profile.provider == .codex ? 150 : 660
        return error != nil || now.timeIntervalSince(snapshot.fetchedAt) > threshold
    }

    public var menuWindow: CodexQuotaWindow? {
        let known = snapshot?.windows.filter(\.usageKnown) ?? []
        let weekly = known.filter { $0.windowDurationMins == 10_080 }
        switch profile.provider {
        case .codex:
            let main = known.filter { $0.id.hasPrefix("codex.") }
            return main.first(where: { $0.windowDurationMins == 10_080 }) ?? main.first
        case .antigravity:
            return (weekly.isEmpty ? known : weekly).max { $0.usedPercent < $1.usedPercent }
        case .claude:
            return known.first(where: { $0.id == "claude.weekly" })
                ?? known.first(where: { $0.id == "claude.session" })
        }
    }
}

@MainActor
public final class UsageMonitor: ObservableObject {
    public typealias Fetch = @Sendable (URL, URL) async throws -> CodexUsageSnapshot
    public typealias Login = @Sendable (URL, URL, @escaping @Sendable (URL) -> Void) async throws -> CodexIdentity
    public typealias AntigravityFetch = @Sendable () async throws -> CodexUsageSnapshot
    public typealias ClaudeFetch = @Sendable (URL, Bool) async throws -> CodexUsageSnapshot

    @Published public private(set) var accounts: [AccountState] = []
    @Published public private(set) var notice: String?
    @Published public private(set) var executableURL: URL?
    @Published public private(set) var isShuttingDown = false
    public let store: AccountStore

    private let fetch: Fetch
    private let authenticate: Login
    private let fetchAntigravity: AntigravityFetch
    private let directAntigravity: AntigravityDirectClient
    private let directCodex: CodexDirectClient
    private let directClaude: ClaudeDirectClient
    private let fetchClaude: ClaudeFetch
    private let clock: @Sendable () -> Date
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var draining: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var disconnecting: Set<UUID> = []
    private var generations: [UUID: UUID] = [:]
    private var retryDates: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private var configurationReadable = true

    private struct CachedSnapshot: Codable {
        let homePath: String
        let snapshot: CodexUsageSnapshot
        let provider: AccountProvider?
        let authentication: AccountAuthentication?
    }

    public init(
        store: AccountStore,
        executableURL: URL?,
        fetch: @escaping Fetch = { executable, home in
            try await CodexClient(executableURL: executable).fetchUsage(home: home)
        },
        authenticate: @escaping Login = { executable, home, onURL in
            try await CodexClient(executableURL: executable).login(home: home, onURL: onURL)
        },
        fetchAntigravity: @escaping AntigravityFetch = {
            try await AntigravityClient().fetchUsage()
        },
        fetchClaude: @escaping ClaudeFetch = { try await ClaudeClient().fetchUsage(home: $0, allowKeychainInteraction: $1) },
        directAntigravity: AntigravityDirectClient = AntigravityDirectClient(),
        directCodex: CodexDirectClient = CodexDirectClient(),
        directClaude: ClaudeDirectClient = ClaudeDirectClient(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.executableURL = executableURL
        self.fetch = fetch
        self.authenticate = authenticate
        self.fetchAntigravity = fetchAntigravity
        self.directAntigravity = directAntigravity
        self.directCodex = directCodex
        self.directClaude = directClaude
        self.fetchClaude = fetchClaude
        self.clock = clock
        do {
            accounts = try store.load().map { profile in
                var state = AccountState(profile: profile)
                let file = store.directory.appendingPathComponent("snapshots/\(profile.id.uuidString).json")
                if FileManager.default.fileExists(atPath: file.path) {
                    do {
                        let cached = try JSONDecoder().decode(CachedSnapshot.self, from: Data(contentsOf: file))
                        if cached.homePath == profile.homePath,
                           (cached.provider ?? .codex) == profile.provider,
                           (cached.authentication ?? .local) == profile.authentication,
                           profile.authentication != .oauth
                            || (profile.oauthIdentity?.accountID != nil
                                && cached.snapshot.identity.accountID == profile.oauthIdentity?.accountID) {
                            state.snapshot = cached.snapshot
                        }
                    } catch {
                        state.error = "이전 사용량을 읽지 못했습니다. 다시 조회해 주세요."
                    }
                }
                return state
            }
        } catch {
            configurationReadable = false
            notice = error.localizedDescription
        }
    }

    public var isWorking: Bool { accounts.contains { $0.isRefreshing || $0.isLoggingIn } }

    public func clearNotice() { notice = nil }

    public func setExecutable(_ url: URL) {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            notice = "실행 가능한 Codex 파일을 선택해 주세요."
            return
        }
        executableURL = url
    }

    @discardableResult
    public func connectExisting(home: URL, name: String) -> UUID? {
        guard configurationReadable else { return nil }
        do {
            let profile = try store.existingProfile(home: home, name: normalizedName(name))
            try store.save(accounts.map(\.profile) + [profile])
            accounts.append(AccountState(profile: profile))
            return profile.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func connectAntigravity() -> UUID? {
        guard configurationReadable else { return nil }
        if let existing = accounts.first(where: {
            $0.profile.provider == .antigravity && $0.profile.authentication == .local
        }) {
            return existing.id
        }
        do {
            let profile = AccountProfile(
                name: "Antigravity", homePath: FileManager.default.homeDirectoryForCurrentUser.path,
                isManaged: false, provider: .antigravity
            )
            try store.save(accounts.map(\.profile) + [profile])
            accounts.append(AccountState(profile: profile))
            return profile.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func connectClaude(home: URL) -> UUID? {
        guard configurationReadable, !isShuttingDown else { return nil }
        if let existing = accounts.first(where: {
            $0.profile.provider == .claude && $0.profile.authentication == .local
        }) { return existing.id }
        do {
            let profile = try store.existingProfile(home: home, name: "Claude", provider: .claude)
            try store.save(accounts.map(\.profile) + [profile])
            accounts.append(AccountState(profile: profile))
            return profile.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func createAntigravityAccount(name: String = "") -> UUID? {
        guard configurationReadable, !isShuttingDown else { return nil }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = AccountProfile(
                name: trimmed.isEmpty ? "Antigravity" : trimmed,
                homePath: store.directory.path, isManaged: false,
                provider: .antigravity, authentication: .oauth
            )
            try store.save(accounts.map(\.profile) + [profile])
            accounts.append(AccountState(profile: profile))
            return profile.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Registers a Codex account that logs in through the app's own ChatGPT
    /// OAuth flow instead of a codex CLI home directory.
    @discardableResult
    public func createCodexAccount(name: String = "") -> UUID? {
        createOAuthAccount(provider: .codex, name: name)
    }

    /// Registers a Claude account with the app's own claude.ai login, independent of Claude Code.
    @discardableResult
    public func createClaudeAccount(name: String = "") -> UUID? {
        createOAuthAccount(provider: .claude, name: name)
    }

    private func createOAuthAccount(provider: AccountProvider, name: String) -> UUID? {
        guard configurationReadable, !isShuttingDown else { return nil }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = AccountProfile(
                name: trimmed.isEmpty ? provider.displayName : trimmed,
                homePath: store.directory.path, isManaged: false,
                provider: provider, authentication: .oauth
            )
            try store.save(accounts.map(\.profile) + [profile])
            accounts.append(AccountState(profile: profile))
            return profile.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func createAccount(name: String) -> UUID? {
        guard configurationReadable else { return nil }
        guard executableURL != nil else {
            notice = "Codex CLI를 찾지 못했습니다. 설정에서 실행 파일을 선택해 주세요."
            return nil
        }
        do {
            let profile = try store.createManagedProfile(name: normalizedName(name))
            try store.save(accounts.map(\.profile) + [profile])
            accounts.append(AccountState(profile: profile))
            return profile.id
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func disconnect(_ id: UUID) -> Task<Void, Never>? {
        guard configurationReadable, !isShuttingDown, !disconnecting.contains(id) else { return nil }
        if let profile = accounts.first(where: { $0.id == id })?.profile,
           profile.authentication == .oauth {
            let provider = profile.provider
            cancel(id)
            disconnecting.insert(id)
            let pending = draining.values.filter { $0.id == id }.map(\.task)
            let generation = UUID()
            generations[id] = generation
            update(id) { $0.isRefreshing = true }
            let task = Task { [weak self, directAntigravity, directCodex, directClaude] in
                defer {
                    self?.disconnecting.remove(id)
                    self?.finish(id, generation: generation)
                }
                for task in pending { await task.value }
                do {
                    switch provider {
                    case .antigravity:
                        try await directAntigravity.disconnect(profileID: id)
                    case .codex:
                        try await directCodex.disconnect(profileID: id)
                    case .claude:
                        try await directClaude.disconnect(profileID: id)
                    }
                    guard let self else { return }
                    try self.store.save(self.accounts.filter { $0.id != id }.map(\.profile))
                    self.accounts.removeAll { $0.id == id }
                    self.invalidateCache(id)
                    self.retryDates[id] = nil
                    self.failures[id] = nil
                } catch {
                    self?.update(id) { $0.error = error.localizedDescription }
                }
            }
            operations[id] = task
            return task
        }
        do {
            try store.save(accounts.filter { $0.id != id }.map(\.profile))
            cancel(id)
            accounts.removeAll { $0.id == id }
            retryDates[id] = nil
            failures[id] = nil
        } catch {
            notice = "연결을 해제하지 못했습니다. \(error.localizedDescription)"
        }
        return nil
    }

    /// Renames an account's display alias and persists it.
    @discardableResult
    public func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].profile.name != trimmed else { return false }
        var profiles = accounts.map(\.profile)
        profiles[index].name = trimmed
        do {
            try store.save(profiles)
            update(id) { $0.profile.name = trimmed }
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    public func move(_ id: UUID, to index: Int) -> Bool {
        guard configurationReadable, accounts.indices.contains(index),
              let from = accounts.firstIndex(where: { $0.id == id }) else { return false }
        if from == index { return true }
        var reordered = accounts
        reordered.insert(reordered.remove(at: from), at: index)
        do {
            try store.save(reordered.map(\.profile))
            accounts = reordered
            return true
        } catch {
            notice = "계정 순서를 저장하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }

    public func cancel(_ id: UUID) {
        let generation = generations.removeValue(forKey: id)
        if let task = operations.removeValue(forKey: id) {
            if let generation { draining[generation] = (id, task) }
            task.cancel()
        }
        update(id) {
            $0.isRefreshing = false
            $0.isLoggingIn = false
        }
    }

    public func stop() {
        for id in Array(operations.keys) { cancel(id) }
    }

    public func stopAndWait() async {
        isShuttingDown = true
        stop()
        let pending = draining.values.map(\.task)
        for task in pending { await task.value }
    }

    @discardableResult
    public func refreshAll(manual: Bool = true) -> [Task<Void, Never>] {
        accounts.compactMap { refresh($0.id, manual: manual) }
    }

    @discardableResult
    public func authorizeKeychain(_ id: UUID) -> Task<Void, Never>? {
        guard let profile = accounts.first(where: { $0.id == id })?.profile,
              profile.authentication == .oauth || profile.provider == .claude else { return nil }
        return refresh(id, manual: true, allowKeychainInteraction: true)
    }

    @discardableResult
    public func refresh(_ id: UUID, manual: Bool = true) -> Task<Void, Never>? {
        refresh(id, manual: manual, allowKeychainInteraction: false)
    }

    private func refresh(_ id: UUID, manual: Bool, allowKeychainInteraction: Bool) -> Task<Void, Never>? {
        guard !isShuttingDown, !disconnecting.contains(id), operations[id] == nil,
              let state = accounts.first(where: { $0.id == id }) else { return nil }
        if !manual {
            if let retry = retryDates[id], clock() < retry { return nil }
            let interval: TimeInterval = state.profile.provider == .codex ? 45 : 300
            if let last = state.snapshot?.fetchedAt, state.error == nil,
               clock().timeIntervalSince(last) < interval { return nil }
        }
        let fetchUsage: AntigravityFetch
        switch state.profile.provider {
        case .codex:
            if state.profile.authentication == .oauth {
                fetchUsage = { [directCodex] in
                    try await directCodex.fetchUsage(
                        profile: state.profile, allowKeychainInteraction: allowKeychainInteraction
                    )
                }
            } else {
                guard let executableURL else {
                    update(id) { $0.error = "Codex CLI를 찾지 못했습니다. 설정에서 실행 파일을 선택해 주세요." }
                    return nil
                }
                fetchUsage = { [fetch, home = state.profile.homeURL] in
                    try await fetch(executableURL, home)
                }
            }
        case .antigravity:
            if state.profile.authentication == .oauth {
                fetchUsage = { [directAntigravity] in
                    try await directAntigravity.fetchUsage(
                        profile: state.profile, allowKeychainInteraction: allowKeychainInteraction
                    )
                }
            } else {
                fetchUsage = fetchAntigravity
            }
        case .claude:
            if state.profile.authentication == .oauth {
                fetchUsage = { [directClaude] in
                    try await directClaude.fetchUsage(
                        profile: state.profile, allowKeychainInteraction: allowKeychainInteraction
                    )
                }
            } else {
                fetchUsage = { [fetchClaude, home = state.profile.homeURL] in
                    try await fetchClaude(home, allowKeychainInteraction)
                }
            }
        }
        let pending = draining.values.filter { $0.id == id }.map(\.task)
        let generation = UUID()
        generations[id] = generation
        update(id) { $0.isRefreshing = true }
        let task = Task { [weak self] in
            defer { self?.finish(id, generation: generation) }
            do {
                for task in pending { await task.value }
                try Task.checkCancellation()
                let snapshot = try await fetchUsage()
                guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                self.update(id) {
                    $0.snapshot = snapshot
                    $0.error = nil
                    $0.needsKeychainAccess = false
                }
                self.failures[id] = nil
                self.retryDates[id] = nil
                self.cache(snapshot, profile: state.profile)
            } catch {
                guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                self.update(id) {
                    $0.error = error.localizedDescription
                    $0.needsKeychainAccess = (error as? CodexOAuthError)?.needsKeychainAccess == true
                        || (error as? AntigravityOAuthError)?.needsKeychainAccess == true
                        || (error as? ClaudeOAuthError)?.needsKeychainAccess == true
                        || (error as? ClaudeClientError).map { if case .keychainUnavailable = $0 { true } else { false } } == true
                }
                let count = min((self.failures[id] ?? 0) + 1, 5)
                self.failures[id] = count
                self.retryDates[id] = self.clock().addingTimeInterval(min(60 * pow(2, Double(count - 1)), 900))
            }
        }
        operations[id] = task
        return task
    }

    @discardableResult
    public func login(_ id: UUID, onURL: @escaping @Sendable (URL) -> Void) -> Task<Void, Never>? {
        guard !isShuttingDown, !disconnecting.contains(id),
              let state = accounts.first(where: { $0.id == id }) else { return nil }
        if state.profile.provider == .antigravity && state.profile.authentication == .local {
            notice = "Antigravity 앱 또는 agy에서 로그인한 뒤 새로고침해 주세요."
            return nil
        }
        if state.profile.provider == .claude && state.profile.authentication == .local {
            notice = "Claude Code에서 로그인한 뒤 새로고침해 주세요."
            return nil
        }
        if accounts.first(where: { $0.id == id })?.isLoggingIn == true,
           let pending = operations[id] {
            return pending
        }
        guard !accounts.contains(where: \.isLoggingIn),
              state.profile.authentication == .oauth || executableURL != nil else {
            notice = "Codex 실행 파일을 확인하거나 진행 중인 로그인을 완료해 주세요."
            return nil
        }
        cancel(id)
        let pending = draining.values.filter { $0.id == id }.map(\.task)
        if state.profile.authentication == .oauth {
            var profiles = accounts.map(\.profile)
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
            profiles[index].oauthIdentity = nil
            do { try store.save(profiles) }
            catch { notice = error.localizedDescription; return nil }
            update(id) { $0.profile.oauthIdentity = nil }
        }
        let generation = UUID()
        generations[id] = generation
        update(id) {
            $0.isLoggingIn = true
            $0.error = nil
            $0.snapshot = nil
        }
        invalidateCache(id)
        let task = Task { [weak self, authenticate, fetch, directAntigravity, directCodex, directClaude, executableURL] in
            defer { self?.finish(id, generation: generation) }
            do {
                for task in pending { await task.value }
                try Task.checkCancellation()
                let snapshot: CodexUsageSnapshot
                var profile = state.profile
                if profile.authentication == .oauth {
                    let identity: CodexIdentity
                    switch profile.provider {
                    case .antigravity:
                        identity = try await directAntigravity.login(profileID: id, onURL: onURL)
                    case .codex:
                        identity = try await directCodex.login(profileID: id, onURL: onURL)
                    case .claude:
                        identity = try await directClaude.login(profileID: id, onURL: onURL)
                    }
                    guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                    profile.oauthIdentity = identity
                    try self.store.save(self.accounts.map { $0.id == id ? profile : $0.profile })
                    self.update(id) {
                        $0.profile = profile
                        $0.isLoggingIn = false
                        $0.isRefreshing = true
                    }
                    switch profile.provider {
                    case .antigravity:
                        snapshot = try await directAntigravity.fetchUsage(profile: profile)
                    case .codex:
                        snapshot = try await directCodex.fetchUsage(profile: profile)
                    case .claude:
                        snapshot = try await directClaude.fetchUsage(profile: profile)
                    }
                } else {
                    guard let executableURL else { return }
                    _ = try await authenticate(executableURL, profile.homeURL, onURL)
                    try Task.checkCancellation()
                    snapshot = try await fetch(executableURL, profile.homeURL)
                }
                guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                self.update(id) {
                    $0.snapshot = snapshot
                    $0.error = nil
                    $0.needsKeychainAccess = false
                }
                self.failures[id] = nil
                self.retryDates[id] = nil
                self.cache(snapshot, profile: profile)
            } catch {
                guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                self.update(id) {
                    $0.error = error.localizedDescription
                    $0.needsKeychainAccess = (error as? CodexOAuthError)?.needsKeychainAccess == true
                        || (error as? AntigravityOAuthError)?.needsKeychainAccess == true
                        || (error as? ClaudeOAuthError)?.needsKeychainAccess == true
                }
            }
        }
        operations[id] = task
        return task
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Codex \(accounts.count + 1)" : trimmed
    }

    private func update(_ id: UUID, _ body: (inout AccountState) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        body(&accounts[index])
    }

    private func finish(_ id: UUID, generation: UUID) {
        draining[generation] = nil
        guard generations[id] == generation else { return }
        generations[id] = nil
        operations[id] = nil
        update(id) {
            $0.isRefreshing = false
            $0.isLoggingIn = false
        }
    }

    private func cache(_ snapshot: CodexUsageSnapshot, profile: AccountProfile) {
        do {
            let folder = store.directory.appendingPathComponent("snapshots", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let file = folder.appendingPathComponent("\(profile.id.uuidString).json")
            try JSONEncoder().encode(CachedSnapshot(
                homePath: profile.homePath, snapshot: snapshot, provider: profile.provider,
                authentication: profile.authentication
            ))
                .write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            notice = "사용량은 조회했지만 로컬 캐시를 저장하지 못했습니다."
        }
    }

    private func invalidateCache(_ id: UUID) {
        let file = store.directory.appendingPathComponent("snapshots/\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            notice = "이전 계정의 로컬 캐시를 삭제하지 못했습니다."
        }
    }
}
