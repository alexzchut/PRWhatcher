import Foundation
import Combine

@MainActor
public final class Store: ObservableObject {
    @Published public var repos: [String] { didSet { defaults.set(repos, forKey: Keys.repos) } }
    @Published public var intervalMinutes: Int {
        didSet {
            let clamped = min(max(intervalMinutes, 1), 60)
            if clamped != intervalMinutes { intervalMinutes = clamped; return }
            defaults.set(intervalMinutes, forKey: Keys.interval)
            if pollTask != nil { startPolling() }
        }
    }
    @Published public private(set) var pullRequests: [PullRequest] = []
    @Published public private(set) var state = TrackerState()
    @Published public private(set) var status = ""
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var isRefreshing = false

    private enum Keys { static let repos = "repos", interval = "intervalMinutes" }

    private let fetcher: PRFetching
    private let notifier: Notifying
    private let defaults: UserDefaults
    private let stateURL: URL
    private var pollTask: Task<Void, Never>?

    public var unreadCount: Int { state.unread.count }

    public init(fetcher: PRFetching, notifier: Notifying, defaults: UserDefaults = .standard, stateURL: URL) {
        self.fetcher = fetcher
        self.notifier = notifier
        self.defaults = defaults
        self.stateURL = stateURL
        self.repos = defaults.stringArray(forKey: Keys.repos) ?? []
        let saved = defaults.integer(forKey: Keys.interval)
        self.intervalMinutes = saved == 0 ? 5 : min(max(saved, 1), 60)
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(TrackerState.self, from: data) {
            self.state = s
        }
    }

    public func addRepo(_ raw: String) -> Bool {
        let r = Store.normalizeRepo(raw)
        guard GitHubClient.validate(repo: r),
              !repos.contains(where: { $0.caseInsensitiveCompare(r) == .orderedSame }) else { return false }
        repos.append(r)
        return true
    }

    /// Accepts `owner/name` or a GitHub URL (https://github.com/owner/name[/pull/1], .git suffix, git@ form).
    public nonisolated static func normalizeRepo(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "git@", "ssh://git@"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        for host in ["www.github.com", "github.com"] where s.lowercased().hasPrefix(host) {
            s = String(s.dropFirst(host.count))
            if s.hasPrefix(":") || s.hasPrefix("/") { s = String(s.dropFirst()) }
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map(String.init)
        guard parts.count == 2 else { return s }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "\(parts[0])/\(name)"
    }

    public func removeRepo(_ r: String) { repos.removeAll { $0 == r } }

    public func startPolling() {
        pollTask?.cancel()
        let seconds = UInt64(intervalMinutes) * 60
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        guard !repos.isEmpty else {
            status = "Add a repository in Settings"
            pullRequests = []
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await fetcher.fetch(repos: repos)
            let fresh = state.apply(result.pullRequests, viewer: result.viewer)
            pullRequests = result.pullRequests
            lastChecked = Date()
            status = ""
            persist()
            for n in notifications(for: fresh, in: result.pullRequests) {
                notifier.notify(title: n.title, body: n.body, url: n.url)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    public func markRead(_ pr: PullRequest) {
        state.markRead(prKey: pr.key)
        persist()
    }

    public func markAllRead() {
        state.markAllRead()
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}
