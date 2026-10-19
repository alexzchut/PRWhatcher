import XCTest
@testable import PRWatcherCore

final class ReviewSummaryTests: XCTestCase {
    private let bot = "copilot-pull-request-reviewer"

    private func prJSON(threads: String = "[]", reviews: String = "[]") -> Data {
        """
        {"data":{"viewer":{"login":"me"},"search":{"nodes":[{"number":1,"title":"t","url":"https://x/1",
        "repository":{"nameWithOwner":"o/r"},
        "reviews":{"nodes":\(reviews)},
        "reviewThreads":{"nodes":\(threads)}}]}}}
        """.data(using: .utf8)!
    }

    private func thread(_ author: String, resolved: Bool) -> String {
        #"{"isResolved":\#(resolved),"root":{"nodes":[{"id":"x","author":{"login":"\#(author)"}}]},"comments":{"nodes":[]}}"#
    }

    private func copilotReview(_ body: String, at: String) -> String {
        let escaped = body.replacingOccurrences(of: "\n", with: "\\n")
        return #"{"id":"r\#(at)","state":"COMMENTED","bodyText":"\#(escaped)","createdAt":"\#(at)","author":{"login":"\#(bot)"}}"#
    }

    private func summary(_ data: Data) throws -> ReviewSummary {
        try GitHubClient.parse(data).pullRequests[0].review
    }

    func testVerdictParsing() {
        XCTAssertEqual(CopilotVerdict.parse("<!-- x -->\n\n🟢 Approval recommended\n\nbody")?.verdict, .green)
        XCTAssertEqual(CopilotVerdict.parse("### 🟡 Changes recommended")?.headline, "Changes recommended")
        XCTAssertEqual(CopilotVerdict.parse("🔵 Needs a closer look\nfoo")?.verdict, .blue)
        XCTAssertNil(CopilotVerdict.parse("just text"))
        XCTAssertNil(CopilotVerdict.parse(nil))
    }

    func testUsesLatestCopilotReview() throws {
        let reviews = "[" + [copilotReview("🟡 Changes recommended", at: "2026-10-18T09:05:36Z"),
                             copilotReview("🟢 Approval recommended", at: "2026-10-18T13:39:56Z"),
                             copilotReview("🔵 Needs a closer look", at: "2026-10-18T10:48:45Z")].joined(separator: ",") + "]"
        let r = try summary(prJSON(reviews: reviews))
        XCTAssertTrue(r.copilotReviewed)
        XCTAssertEqual(r.copilotVerdict, .green)
        XCTAssertEqual(r.copilotHeadline, "Approval recommended")
        XCTAssertEqual(r.copilotBody, "🟢 Approval recommended")
    }

    func testCopilotReviewIsNotAnActivityEvent() throws {
        let data = prJSON(reviews: "[\(copilotReview("🟢 Approval recommended", at: "2026-10-18T13:39:56Z"))]")
        let pr = try GitHubClient.parse(data).pullRequests[0]
        XCTAssertTrue(pr.events.isEmpty)
        XCTAssertEqual(pr.review.copilotVerdict, .green)
    }

    func testBlueVerdict() throws {
        let r = try summary(prJSON(reviews: "[\(copilotReview("🔵 Needs a closer look", at: "2026-10-18T10:48:45Z"))]"))
        XCTAssertEqual(r.copilotVerdict, .blue)
    }

    func testUnresolvedCountsSplitByAuthor() throws {
        let t = "[" + [thread(bot, resolved: false), thread(bot, resolved: true), thread("bob", resolved: false),
                       thread("carol", resolved: false), thread("bob", resolved: true), thread("me", resolved: false)]
            .joined(separator: ",") + "]"
        let r = try summary(prJSON(threads: t))
        XCTAssertEqual(r.copilotUnresolved, 1)
        XCTAssertTrue(r.copilotReviewed)             // inferred from its threads
        XCTAssertNil(r.copilotVerdict)               // no review body to read
        XCTAssertEqual(r.otherUnresolved, 2)         // resolved and own threads excluded
    }

    func testNoCopilotInvolvement() throws {
        let r = try summary(prJSON(threads: "[\(thread("bob", resolved: false))]"))
        XCTAssertFalse(r.copilotReviewed)
        XCTAssertEqual(r.otherUnresolved, 1)
    }

    func testIsCopilot() {
        XCTAssertTrue(ReviewSummary.isCopilot("Copilot"))
        XCTAssertTrue(ReviewSummary.isCopilot("copilot-pull-request-reviewer"))
        XCTAssertFalse(ReviewSummary.isCopilot("alice"))
        XCTAssertFalse(ReviewSummary.isCopilot(nil))
    }
}
