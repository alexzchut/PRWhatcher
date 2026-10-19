import Foundation

public protocol Notifying {
    func notify(title: String, body: String, url: URL?)
}

/// Builds one notification per PR from a batch of new events.
public func notifications(for events: [ActivityEvent], in prs: [PullRequest]) -> [(title: String, body: String, url: URL?)] {
    let byKey = Dictionary(uniqueKeysWithValues: prs.map { ($0.key, $0) })
    let grouped = Dictionary(grouping: events, by: \.prKey)
    return grouped.keys.sorted().compactMap { key in
        guard let pr = byKey[key], let evs = grouped[key] else { return nil }
        let latest = evs.max { $0.createdAt < $1.createdAt }!
        func count(_ k: ActivityKind, _ one: String, _ many: String) -> String? {
            let n = evs.filter { $0.kind == k }.count
            return n == 0 ? nil : (n == 1 ? "1 \(one)" : "\(n) \(many)")
        }
        let parts = [count(.comment, "comment", "comments"),
                     count(.review, "review", "reviews"),
                     count(.commit, "commit", "commits")].compactMap { $0 }
        return (title: "\(pr.repo) #\(pr.number)",
                body: "\(parts.joined(separator: ", ")) — latest from \(latest.actor): \(latest.summary)",
                url: evs.count == 1 ? latest.url : pr.url)
    }
}
