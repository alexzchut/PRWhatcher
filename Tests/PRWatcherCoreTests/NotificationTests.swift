import XCTest
@testable import PRWatcherCore

final class NotificationTests: XCTestCase {
    func testGroupsPerPRWithCounts() {
        let p1 = pr(1, events: []), p2 = pr(2, events: [])
        let evs = [event("a", pr: "o/r#1", at: 1), event("b", pr: "o/r#1", kind: .review, actor: "bob", at: 3),
                   event("c", pr: "o/r#1", at: 2), event("d", pr: "o/r#2", kind: .commit, actor: "dan", at: 1)]
        let n = notifications(for: evs, in: [p1, p2])
        XCTAssertEqual(n.map(\.title), ["o/r #1", "o/r #2"])
        XCTAssertEqual(n[0].body, "2 comments, 1 review — latest from bob: s-b")
        XCTAssertEqual(n[0].url, p1.url)                           // several events -> PR page
        XCTAssertEqual(n[1].body, "1 commit — latest from dan: s-d")
        XCTAssertEqual(n[1].url?.absoluteString, "https://x/d")    // single event -> deep link
    }

    func testNoEventsNoNotifications() {
        XCTAssertTrue(notifications(for: [], in: [pr(1, events: [])]).isEmpty)
    }

    func testUnknownPRIgnored() {
        XCTAssertTrue(notifications(for: [event("a", pr: "x/y#9")], in: [pr(1, events: [])]).isEmpty)
    }
}
