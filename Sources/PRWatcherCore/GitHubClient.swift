import Foundation

public enum GitHubError: LocalizedError {
    case ghNotFound
    case tokenFailed(String)
    case http(Int)
    case api(String)
    case badRepo(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound: return "gh CLI not found (install it and run `gh auth login`)"
        case .tokenFailed(let m): return "`gh auth token` failed: \(m)"
        case .http(let c): return c == 401 ? "GitHub rejected the token (401)" : "GitHub HTTP \(c)"
        case .api(let m): return "GitHub: \(m)"
        case .badRepo(let r): return "Invalid repo “\(r)” (use owner/name)"
        }
    }
}

public protocol PRFetching {
    func fetch(repos: [String]) async throws -> FetchResult
}

public final class GitHubClient: PRFetching {
    private var token: String?
    private let session: URLSession
    private let tokenProvider: () throws -> String

    public init(session: URLSession = .shared,
                tokenProvider: @escaping () throws -> String = GitHubClient.readGhToken) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    static let query = """
    query($q: String!, $a: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 50) { nodes { ...PRFields } }
      assigned: search(query: $a, type: ISSUE, first: 50) { nodes { ...PRFields } }
    }
    fragment PRFields on PullRequest {
          number title url reviewDecision
          repository { nameWithOwner }
          comments(last: 30) { nodes { id url bodyText createdAt author { login } } }
          reviews(last: 30) { nodes { id url state bodyText createdAt author { login } } }
          reviewThreads(last: 50) { nodes {
            isResolved
            root: comments(first: 1) { nodes { id author { login } } }
            comments(last: 10) { nodes { id url bodyText createdAt author { login } } }
          } }
          commits(last: 30) { nodes { commit {
            oid url messageHeadline committedDate
            author { name user { login } }
          } } }
    }
    """

    public static func validate(repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    public func fetch(repos: [String]) async throws -> FetchResult {
        for r in repos where !Self.validate(repo: r) { throw GitHubError.badRepo(r) }
        let scope = repos.map { "repo:\($0)" }.joined(separator: " ")
        let q = "is:pr is:open draft:false author:@me " + scope
        let a = "is:pr is:open draft:false assignee:@me -author:@me " + scope
        do {
            return try await request(q, a)
        } catch GitHubError.http(401) {
            token = nil          // token may have been rotated; retry once
            return try await request(q, a)
        }
    }

    /// Cheap call used by Settings → "Test token".
    public func viewerLogin() async throws -> String {
        try await request("is:pr is:open author:@me repo:github/gitignore",
                          "is:pr is:open assignee:@me repo:github/gitignore").viewer
    }

    private func request(_ q: String, _ a: String) async throws -> FetchResult {
        let token = try await currentToken()
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PRWatcher", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.query, "variables": ["q": q, "a": a],
        ])
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubError.http(http.statusCode)
        }
        return try Self.parse(data)
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        let provider = tokenProvider
        let t = try await Task.detached { try provider() }.value
        token = t
        return t
    }

    public static func readGhToken() throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: FileManager.default.isExecutableFile) else {
            throw GitHubError.ghNotFound
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "token"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !o.isEmpty else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw GitHubError.tokenFailed(e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return o
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) throws -> FetchResult {
        let resp = try JSONDecoder().decode(Response.self, from: data)
        if let first = resp.errors?.first { throw GitHubError.api(first.message) }
        guard let body = resp.data else { throw GitHubError.api("empty response") }

        let viewer = body.viewer.login ?? ""
        let prs = body.search.nodes.compactMap { $0?.toPullRequest(viewer: viewer) }
        let assigned = (body.assigned?.nodes ?? []).compactMap { $0?.toPullRequest(viewer: viewer) }
        return FetchResult(viewer: viewer, pullRequests: prs, assigned: assigned)
    }

    private struct Response: Decodable {
        let data: Body?
        let errors: [Err]?
    }
    private struct Err: Decodable { let message: String }
    private struct Body: Decodable {
        let viewer: Login
        let search: Search
        let assigned: Search?
    }
    private struct Login: Decodable { let login: String? }
    private struct Search: Decodable { let nodes: [PRNode?] }
    private struct Nodes<T: Decodable>: Decodable { let nodes: [T?]? }

    private struct CommentNode: Decodable {
        let id: String
        let url: String?
        let bodyText: String?
        let createdAt: String?
        let state: String?
        let author: Login?
    }
    private struct ThreadNode: Decodable {
        let isResolved: Bool?
        let root: Nodes<CommentNode>?
        let comments: Nodes<CommentNode>?
    }
    private struct GitActor: Decodable { let name: String?; let user: Login? }
    private struct CommitBody: Decodable {
        let oid: String
        let url: String?
        let messageHeadline: String?
        let committedDate: String?
        let author: GitActor?
    }
    private struct CommitNode: Decodable { let commit: CommitBody }
    private struct Repo: Decodable { let nameWithOwner: String }

    private struct PRNode: Decodable {
        let number: Int?
        let title: String?
        let url: String?
        let reviewDecision: String?
        let repository: Repo?
        let comments: Nodes<CommentNode>?
        let reviews: Nodes<CommentNode>?
        let reviewThreads: Nodes<ThreadNode>?
        let commits: Nodes<CommitNode>?

        func toPullRequest(viewer: String) -> PullRequest? {
            guard let number, let title, let url, let prURL = URL(string: url),
                  let repo = repository?.nameWithOwner else { return nil }
            let key = "\(repo)#\(number)"
            var events: [ActivityEvent] = []

            func add(_ c: CommentNode, kind: ActivityKind, summary: String) {
                // Copilot feedback is shown in the Review column, not as activity.
                if ReviewSummary.isCopilot(c.author?.login) { return }
                // Copilot feedback is shown in the Review column, not as activity.
                if ReviewSummary.isCopilot(c.author?.login) { return }
                events.append(ActivityEvent(
                    id: c.id, prKey: key, kind: kind,
                    actor: c.author?.login ?? "ghost",
                    createdAt: parseDate(c.createdAt),
                    url: c.url.flatMap(URL.init(string:)) ?? prURL,
                    summary: summary))
            }

            for c in comments?.nodes?.compactMap({ $0 }) ?? [] {
                add(c, kind: .comment, summary: snippet(c.bodyText))
            }
            for t in reviewThreads?.nodes?.compactMap({ $0 }) ?? [] {
                for c in t.comments?.nodes?.compactMap({ $0 }) ?? [] {
                    add(c, kind: .comment, summary: snippet(c.bodyText))
                }
            }
            for r in reviews?.nodes?.compactMap({ $0 }) ?? [] {
                let body = snippet(r.bodyText)
                // Pending reviews are private; empty "commented" reviews just wrap inline comments.
                // Copilot's review summary is surfaced as the verdict dot, not as an activity item.
                if ReviewSummary.isCopilot(r.author?.login) { continue }
                if r.state == "PENDING" || (r.state == "COMMENTED" && body.isEmpty) { continue }
                let verb: String
                switch r.state {
                case "APPROVED": verb = "approved"
                case "CHANGES_REQUESTED": verb = "requested changes"
                case "DISMISSED": verb = "review dismissed"
                default: verb = "reviewed"
                }
                add(r, kind: .review, summary: body.isEmpty ? verb : "\(verb): \(body)")
            }
            for n in commits?.nodes?.compactMap({ $0 }) ?? [] {
                let c = n.commit
                events.append(ActivityEvent(
                    id: c.oid, prKey: key, kind: .commit,
                    actor: c.author?.user?.login ?? c.author?.name ?? "unknown",
                    createdAt: parseDate(c.committedDate),
                    url: c.url.flatMap(URL.init(string:)) ?? prURL,
                    summary: c.messageHeadline ?? "commit"))
            }
            return PullRequest(repo: repo, number: number, title: title, url: prURL, events: events,
                               status: PRStatus(reviewDecision: reviewDecision),
                               review: reviewSummary(viewer: viewer))
        }

        private func reviewSummary(viewer: String) -> ReviewSummary {
            var copilotUnresolved = 0, other = 0
            for t in reviewThreads?.nodes?.compactMap({ $0 }) ?? [] where t.isResolved == false {
                let author = t.root?.nodes?.compactMap({ $0 }).first?.author?.login
                if ReviewSummary.isCopilot(author) { copilotUnresolved += 1 }
                else if author?.caseInsensitiveCompare(viewer) != .orderedSame { other += 1 }
            }
            let copilotReviews = (reviews?.nodes?.compactMap { $0 } ?? [])
                .filter { ReviewSummary.isCopilot($0.author?.login) }
            let latest = copilotReviews.max { parseDate($0.createdAt) < parseDate($1.createdAt) }
            let marker = CopilotVerdict.parse(latest?.bodyText)
            return ReviewSummary(copilotReviewed: latest != nil || copilotUnresolved > 0,
                                 copilotVerdict: marker?.verdict, copilotHeadline: marker?.headline,
                                 copilotBody: reviewBody(latest?.bodyText),
                                 copilotUnresolved: copilotUnresolved, otherUnresolved: other)
        }
    }
}

private func reviewBody(_ s: String?) -> String? {
    let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    return t.count > 1500 ? String(t.prefix(1500)) + "…" : t
}

private func snippet(_ s: String?) -> String {
    let flat = (s ?? "").replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
}

private func parseDate(_ s: String?) -> Date {
    guard let s else { return Date() }
    return ISO8601DateFormatter().date(from: s) ?? Date()
}
