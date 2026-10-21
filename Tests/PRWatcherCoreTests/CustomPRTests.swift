import XCTest
@testable import PRWatcherCore

final class CustomPRTests: XCTestCase {
    func testPRRefParsing() {
        let want = PRRef(owner: "applicaster", name: "zapp", number: 5052)
        for input in ["https://github.com/applicaster/zapp/pull/5052",
                      "https://github.com/applicaster/zapp/pull/5052/files",
                      "https://github.com/applicaster/zapp/pull/5052#pullrequestreview-5563215696",
                      "github.com/applicaster/zapp/pull/5052?diff=split",
                      "applicaster/zapp/pull/5052",
                      "applicaster/zapp#5052",
                      "  http://www.github.com/applicaster/zapp/pull/5052  "] {
            XCTAssertEqual(PRRef.parse(input), want, input)
        }
        XCTAssertEqual(want.key, "applicaster/zapp#5052")
        XCTAssertEqual(want.url.absoluteString, "https://github.com/applicaster/zapp/pull/5052")
    }

    func testPRRefRejectsBadInput() {
        for bad in ["", "zapp", "applicaster/zapp", "applicaster/zapp/issues/5", "applicaster/zapp/pull/abc",
                    "applicaster/zapp/pull/0", "a b/c/pull/1", "o/r\"x/pull/1", "o/r#abc"] {
            XCTAssertNil(PRRef.parse(bad), bad)
        }
    }

    func testBuildQueryAddsAliasesAndOptionalSearch() {
        let refs = [PRRef(owner: "o", name: "r", number: 1), PRRef(owner: "x", name: "y-z", number: 22)]
        let q = GitHubClient.buildQuery(includeSearch: true, custom: refs)
        XCTAssertTrue(q.hasPrefix("query($q: String!, $a: String!, $r: String!)"))
        XCTAssertTrue(q.contains(#"c0: repository(owner: "o", name: "r") { pullRequest(number: 1)"#))
        XCTAssertTrue(q.contains(#"c1: repository(owner: "x", name: "y-z") { pullRequest(number: 22)"#))
        let noSearch = GitHubClient.buildQuery(includeSearch: false, custom: refs)
        XCTAssertTrue(noSearch.hasPrefix("query {"))
        XCTAssertFalse(noSearch.contains("search("))
        XCTAssertTrue(noSearch.contains("fragment PRFields"))
    }

    func testParseCustomResultsKeepOrderAndSkipMissing() throws {
        let json = """
        {"data":{"viewer":{"login":"me"},
         "c0":{"pullRequest":{"number":1,"title":"one","url":"https://x/1","state":"OPEN","isDraft":false,
               "repository":{"nameWithOwner":"o/r"}}},
         "c1":null,
         "c2":{"pullRequest":{"number":3,"title":"three","url":"https://x/3","state":"MERGED","isDraft":false,
               "repository":{"nameWithOwner":"o/r"}}}},
         "errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}
        """.data(using: .utf8)!
        let refs = (1...3).map { PRRef(owner: "o", name: "r", number: $0) }
        let r = try GitHubClient.parse(json, custom: refs)
        XCTAssertEqual(r.custom.map(\.key), ["o/r#1", "o/r#3"])
        XCTAssertEqual(r.custom[1].status, .merged)
        XCTAssertTrue(r.pullRequests.isEmpty)
    }

    func testOtherErrorsStillThrowWithCustom() {
        let json = #"{"data":{"viewer":{"login":"me"}},"errors":[{"type":"FORBIDDEN","message":"nope"}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GitHubClient.parse(json))
    }

    func testStatusFromStateAndDraft() {
        XCTAssertEqual(PRStatus(reviewDecision: "APPROVED", state: "MERGED"), .merged)
        XCTAssertEqual(PRStatus(reviewDecision: nil, state: "CLOSED"), .closed)
        XCTAssertEqual(PRStatus(reviewDecision: "APPROVED", state: "OPEN", isDraft: true), .draft)
        XCTAssertEqual(PRStatus(reviewDecision: "APPROVED", state: "OPEN"), .approved)
        XCTAssertEqual(PRStatus.draft.label, "Draft")
        XCTAssertEqual(PRStatus.merged.label, "Merged")
    }

    func testTrackerForget() {
        var s = TrackerState()
        s.apply([pr(1, events: [])], viewer: "me")
        s.apply([pr(1, events: [event("a")])], viewer: "me")
        s.forget(prKey: "o/r#1")
        XCTAssertTrue(s.unread.isEmpty)
        XCTAssertNil(s.known["o/r#1"])
    }
}
