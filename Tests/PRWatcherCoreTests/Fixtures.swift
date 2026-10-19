import Foundation
@testable import PRWatcherCore

let sampleJSON = """
{"data":{"viewer":{"login":"me"},"search":{"nodes":[
 {"number":7,"title":"Add thing","url":"https://github.com/o/r/pull/7","repository":{"nameWithOwner":"o/r"},
  "comments":{"nodes":[
    {"id":"c1","url":"https://github.com/o/r/pull/7#c1","bodyText":"looks\\ngood","createdAt":"2026-01-01T10:00:00Z","author":{"login":"alice"}},
    {"id":"c2","url":null,"bodyText":"mine","createdAt":"2026-01-01T11:00:00Z","author":{"login":"me"}},
    null]},
  "reviews":{"nodes":[
    {"id":"r1","url":"https://x/r1","state":"APPROVED","bodyText":"","createdAt":"2026-01-02T10:00:00Z","author":{"login":"bob"}},
    {"id":"r2","url":"https://x/r2","state":"COMMENTED","bodyText":"","createdAt":"2026-01-02T10:00:00Z","author":{"login":"bob"}},
    {"id":"r3","url":"https://x/r3","state":"PENDING","bodyText":"draft","createdAt":"2026-01-02T10:00:00Z","author":{"login":"bob"}},
    {"id":"r4","url":"https://x/r4","state":"CHANGES_REQUESTED","bodyText":"fix it","createdAt":"2026-01-02T12:00:00Z","author":null}]},
  "reviewThreads":{"nodes":[{"comments":{"nodes":[
    {"id":"t1","url":"https://x/t1","bodyText":"inline","createdAt":"2026-01-03T10:00:00Z","author":{"login":"carol"}}]}}]},
  "commits":{"nodes":[
    {"commit":{"oid":"abc","url":"https://x/abc","messageHeadline":"fix lint","committedDate":"2026-01-04T10:00:00Z","author":{"name":"Dan","user":{"login":"dan"}}}},
    {"commit":{"oid":"def","url":null,"messageHeadline":"my commit","committedDate":"2026-01-04T11:00:00Z","author":{"name":"Me","user":{"login":"me"}}}},
    {"commit":{"oid":"ghi","url":null,"messageHeadline":"no user","committedDate":"2026-01-04T12:00:00Z","author":{"name":"Eve","user":null}}}]}},
 {}
]}}}
""".data(using: .utf8)!

func event(_ id: String, pr: String = "o/r#1", kind: ActivityKind = .comment, actor: String = "alice",
           at t: TimeInterval = 0, url: String? = nil) -> ActivityEvent {
    ActivityEvent(id: id, prKey: pr, kind: kind, actor: actor, createdAt: Date(timeIntervalSince1970: t),
                  url: URL(string: url ?? "https://x/\(id)"), summary: "s-\(id)")
}

func pr(_ number: Int, repo: String = "o/r", events: [ActivityEvent]) -> PullRequest {
    PullRequest(repo: repo, number: number, title: "T\(number)",
                url: URL(string: "https://github.com/\(repo)/pull/\(number)")!, events: events)
}
