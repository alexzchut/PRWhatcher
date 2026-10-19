import XCTest
@testable import PRWatcherCore

final class CopilotCommentTests: XCTestCase {
    func testCopilotCommentsAreNotActivityButStillCounted() throws {
        let bot = "copilot-pull-request-reviewer"
        let json = """
        {"data":{"viewer":{"login":"me"},"search":{"nodes":[{"number":1,"title":"t","url":"https://x/1",
        "repository":{"nameWithOwner":"o/r"},
        "comments":{"nodes":[{"id":"c1","url":null,"bodyText":"hi","createdAt":"2026-01-01T10:00:00Z","author":{"login":"Copilot"}},
                             {"id":"c2","url":null,"bodyText":"hi","createdAt":"2026-01-01T10:00:00Z","author":{"login":"bob"}}]},
        "reviewThreads":{"nodes":[{"isResolved":false,"root":{"nodes":[{"id":"x","author":{"login":"\(bot)"}}]},
          "comments":{"nodes":[{"id":"t1","url":null,"bodyText":"inline","createdAt":"2026-01-01T10:00:00Z","author":{"login":"\(bot)"}}]}}]}}]}}}
        """.data(using: .utf8)!
        let pr = try GitHubClient.parse(json).pullRequests[0]
        XCTAssertEqual(pr.events.map(\.id), ["c2"])          // only bob's comment is activity
        XCTAssertEqual(pr.review.copilotUnresolved, 1)       // Copilot's thread still counted in the Review column
    }
}
