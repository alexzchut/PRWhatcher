import Foundation

/// Persisted view of what we have already seen, and what the user has not yet read.
public struct TrackerState: Codable, Equatable {
    public var known: [String: Set<String>] = [:]   // prKey -> event ids already seen
    public var unread: [ActivityEvent] = []
    public var copilotAcked: [String: Int] = [:]    // prKey -> unresolved Copilot threads when the PR was last opened

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decode([String: Set<String>].self, forKey: .known)
        unread = try c.decode([ActivityEvent].self, forKey: .unread)
        copilotAcked = try c.decodeIfPresent([String: Int].self, forKey: .copilotAcked) ?? [:]
    }

    /// Merges a fresh fetch into the state and returns the events that are new
    /// (not authored by `viewer`, not seen before). A PR seen for the first time is
    /// baselined silently so enabling the app does not produce a flood of alerts.
    @discardableResult
    public mutating func apply(_ prs: [PullRequest], viewer: String) -> [ActivityEvent] {
        var fresh: [ActivityEvent] = []
        var nextKnown: [String: Set<String>] = [:]

        for pr in prs {
            let others = pr.events.filter { $0.actor.caseInsensitiveCompare(viewer) != .orderedSame }
            let ids = Set(others.map(\.id))
            if let seen = known[pr.key] {
                fresh += others.filter { !seen.contains($0.id) }
                nextKnown[pr.key] = seen.union(ids)
            } else {
                nextKnown[pr.key] = ids
            }
        }

        known = nextKnown
        let present = Set(prs.flatMap(\.events).map(\.id))   // drops stale items (closed PRs, filtered kinds)
        unread = (unread + fresh)
            .filter { present.contains($0.id) }
            .reduce(into: [ActivityEvent]()) { acc, e in
                if !acc.contains(where: { $0.id == e.id }) { acc.append(e) }
            }
        return fresh
    }

    /// Drops everything remembered about a PR that is no longer watched.
    public mutating func forget(prKey: String) {
        known[prKey] = nil
        copilotAcked[prKey] = nil
        unread.removeAll { $0.prKey == prKey }
    }

    public mutating func markRead(prKey: String) {
        unread.removeAll { $0.prKey == prKey }
    }

    public mutating func markAllRead() {
        unread.removeAll()
    }

    public func unread(for prKey: String) -> [ActivityEvent] {
        unread.filter { $0.prKey == prKey }.sorted { $0.createdAt > $1.createdAt }
    }
}
