import Foundation

public enum ActivityKind: String, Codable {
    case comment, review, commit
}

public struct ActivityEvent: Codable, Hashable, Identifiable {
    public let id: String
    public let prKey: String
    public let kind: ActivityKind
    public let actor: String
    public let createdAt: Date
    public let url: URL?
    public let summary: String

    public init(id: String, prKey: String, kind: ActivityKind, actor: String,
                createdAt: Date, url: URL?, summary: String) {
        self.id = id
        self.prKey = prKey
        self.kind = kind
        self.actor = actor
        self.createdAt = createdAt
        self.url = url
        self.summary = summary
    }
}

public enum PRStatus: String, Codable {
    case open, approved, changesRequested, draft, merged, closed

    public var label: String {
        switch self {
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .open: return "Open"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        }
    }

    public init(reviewDecision: String?, state: String? = nil, isDraft: Bool = false) {
        switch (state, reviewDecision) {
        case ("MERGED", _): self = .merged
        case ("CLOSED", _): self = .closed
        case (_, _) where isDraft: self = .draft
        case (_, "APPROVED"): self = .approved
        case (_, "CHANGES_REQUESTED"): self = .changesRequested
        default: self = .open
        }
    }
}

/// Verdict Copilot puts at the top of its review ("🟢 Approval recommended", "🟡 Changes recommended",
/// "🔵 Needs a closer look").
public enum CopilotVerdict: String, Codable {
    case green, yellow, blue

    /// Finds the verdict marker in a Copilot review body and returns it with its headline text.
    public static func parse(_ body: String?) -> (verdict: CopilotVerdict, headline: String)? {
        guard let body else { return nil }
        let markers: [(Character, CopilotVerdict)] = [("🟢", .green), ("🟡", .yellow), ("🔵", .blue)]
        for line in body.split(whereSeparator: \.isNewline) {
            guard let (m, v) = markers.first(where: { line.contains($0.0) }) else { continue }
            let text = line.drop(while: { $0 == "#" || $0 == " " })
                .replacingOccurrences(of: String(m), with: "")
                .trimmingCharacters(in: .whitespaces)
            return (v, text)
        }
        return nil
    }
}

public struct ReviewSummary: Codable, Hashable {
    public var copilotReviewed: Bool
    public var copilotVerdict: CopilotVerdict?   // from the latest Copilot review
    public var copilotHeadline: String?
    public var copilotBody: String?              // text of the latest Copilot review, for the hover bubble
    public var copilotUnresolved: Int
    public var otherUnresolved: Int              // unresolved threads started by anyone but Copilot / you

    public init(copilotReviewed: Bool = false, copilotVerdict: CopilotVerdict? = nil, copilotHeadline: String? = nil,
                copilotBody: String? = nil, copilotUnresolved: Int = 0, otherUnresolved: Int = 0) {
        self.copilotReviewed = copilotReviewed
        self.copilotVerdict = copilotVerdict
        self.copilotHeadline = copilotHeadline
        self.copilotBody = copilotBody
        self.copilotUnresolved = copilotUnresolved
        self.otherUnresolved = otherUnresolved
    }

    public static func isCopilot(_ login: String?) -> Bool {
        login?.lowercased().contains("copilot") ?? false
    }
}

public struct PullRequest: Codable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String          // "owner/repo#123"
    public let repo: String
    public let number: Int
    public let title: String
    public let url: URL
    public let events: [ActivityEvent]
    public let status: PRStatus
    public let review: ReviewSummary

    public init(repo: String, number: Int, title: String, url: URL, events: [ActivityEvent],
                status: PRStatus = .open, review: ReviewSummary = ReviewSummary()) {
        self.status = status
        self.review = review
        self.key = "\(repo)#\(number)"
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.events = events
    }
}

public struct FetchResult {
    public let viewer: String
    public let pullRequests: [PullRequest]
    public let assigned: [PullRequest]        // open PRs assigned to the viewer (authored by others)
    public let custom: [PullRequest]          // PRs added by hand; refs that can't be read are omitted

    public init(viewer: String, pullRequests: [PullRequest], assigned: [PullRequest] = [], custom: [PullRequest] = []) {
        self.viewer = viewer
        self.pullRequests = pullRequests
        self.assigned = assigned
        self.custom = custom
    }
}
