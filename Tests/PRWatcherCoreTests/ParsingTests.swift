import XCTest
@testable import PRWatcherCore

final class ParsingTests: XCTestCase {
    func testParsesViewerAndPR() throws {
        let r = try GitHubClient.parse(sampleJSON)
        XCTAssertEqual(r.viewer, "me")
        XCTAssertEqual(r.pullRequests.count, 1)   // empty `{}` node is skipped
        let p = r.pullRequests[0]
        XCTAssertEqual(p.key, "o/r#7")
        XCTAssertEqual(p.title, "Add thing")
    }

    func testEventsMapped() throws {
        let ev = try GitHubClient.parse(sampleJSON).pullRequests[0].events
        let byID = Dictionary(uniqueKeysWithValues: ev.map { ($0.id, $0) })
        XCTAssertEqual(byID["c1"]?.summary, "looks good")          // newline flattened
        XCTAssertEqual(byID["c1"]?.kind, .comment)
        XCTAssertEqual(byID["c2"]?.url?.absoluteString, "https://github.com/o/r/pull/7")  // falls back to PR url
        XCTAssertEqual(byID["t1"]?.actor, "carol")                 // inline thread comment
        XCTAssertEqual(byID["r1"]?.summary, "approved")
        XCTAssertEqual(byID["r4"]?.summary, "requested changes: fix it")
        XCTAssertEqual(byID["r4"]?.actor, "ghost")                 // null author
        XCTAssertEqual(byID["abc"]?.actor, "dan")
        XCTAssertEqual(byID["abc"]?.kind, .commit)
        XCTAssertEqual(byID["ghi"]?.actor, "Eve")                  // no linked user -> git name
        XCTAssertEqual(byID["c1"]?.createdAt, ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z"))
    }

    func testSkipsPendingAndEmptyCommentedReviews() throws {
        let ids = Set(try GitHubClient.parse(sampleJSON).pullRequests[0].events.map(\.id))
        XCTAssertFalse(ids.contains("r2"))
        XCTAssertFalse(ids.contains("r3"))
    }

    func testLongSnippetTruncated() throws {
        let long = String(repeating: "a", count: 300)
        let json = """
        {"data":{"viewer":{"login":"me"},"search":{"nodes":[{"number":1,"title":"t","url":"https://x/1",
        "repository":{"nameWithOwner":"o/r"},"comments":{"nodes":[{"id":"c","url":null,"bodyText":"\(long)",
        "createdAt":"2026-01-01T10:00:00Z","author":{"login":"a"}}]}}]}}}
        """.data(using: .utf8)!
        let s = try GitHubClient.parse(json).pullRequests[0].events[0].summary
        XCTAssertEqual(s.count, 141)
        XCTAssertTrue(s.hasSuffix("…"))
    }

    func testApiErrorThrows() {
        let json = #"{"errors":[{"message":"Bad credentials"}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GitHubClient.parse(json)) {
            XCTAssertEqual($0.localizedDescription, "GitHub: Bad credentials")
        }
    }

    func testEmptyResponseThrows() {
        XCTAssertThrowsError(try GitHubClient.parse("{}".data(using: .utf8)!))
    }

    func testReviewDecisionMapsToStatus() {
        XCTAssertEqual(PRStatus(reviewDecision: "APPROVED"), .approved)
        XCTAssertEqual(PRStatus(reviewDecision: "CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(PRStatus(reviewDecision: "REVIEW_REQUIRED"), .open)
        XCTAssertEqual(PRStatus(reviewDecision: nil), .open)
        XCTAssertEqual(PRStatus.changesRequested.label, "Changes requested")
    }

    func testParsedPRCarriesStatus() throws {
        let json = String(decoding: sampleJSON, as: UTF8.self)
            .replacingOccurrences(of: #""number":7,"#, with: #""number":7,"reviewDecision":"APPROVED","#)
        XCTAssertEqual(try GitHubClient.parse(Data(json.utf8)).pullRequests[0].status, .approved)
        XCTAssertEqual(try GitHubClient.parse(sampleJSON).pullRequests[0].status, .open)
    }

    func testParsesAssignedList() throws {
        let json = """
        {"data":{"viewer":{"login":"me"},
        "search":{"nodes":[]},
        "assigned":{"nodes":[{"number":9,"title":"Assigned one","url":"https://x/9","reviewDecision":"CHANGES_REQUESTED",
          "repository":{"nameWithOwner":"o/other"}}, {}]}}}
        """.data(using: .utf8)!
        let r = try GitHubClient.parse(json)
        XCTAssertTrue(r.pullRequests.isEmpty)
        XCTAssertEqual(r.assigned.map(\.key), ["o/other#9"])
        XCTAssertEqual(r.assigned[0].status, .changesRequested)
        XCTAssertTrue(try GitHubClient.parse(sampleJSON).assigned.isEmpty)   // field absent -> empty
    }

    func testRepoValidation() {
        XCTAssertTrue(GitHubClient.validate(repo: "owner/name"))
        for bad in ["", "owner", "owner/", "/name", "a/b/c", "a b/c"] {
            XCTAssertFalse(GitHubClient.validate(repo: bad), bad)
        }
    }
}
