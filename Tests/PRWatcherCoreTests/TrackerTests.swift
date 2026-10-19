import XCTest
@testable import PRWatcherCore

final class TrackerTests: XCTestCase {
    func testFirstSeenPRIsBaselinedSilently() {
        var s = TrackerState()
        let fresh = s.apply([pr(1, events: [event("a"), event("b")])], viewer: "me")
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertTrue(s.unread.isEmpty)
        XCTAssertEqual(s.known["o/r#1"], ["a", "b"])
    }

    func testNewOthersEventsDetectedOnce() {
        var s = TrackerState()
        s.apply([pr(1, events: [event("a")])], viewer: "me")
        let next = [pr(1, events: [event("a"), event("b"), event("c", kind: .commit)])]
        XCTAssertEqual(Set(s.apply(next, viewer: "me").map(\.id)), ["b", "c"])
        XCTAssertEqual(s.unread.count, 2)
        XCTAssertTrue(s.apply(next, viewer: "me").isEmpty)       // same poll again: no dupes
        XCTAssertEqual(s.unread.count, 2)
    }

    func testOwnEventsIgnoredCaseInsensitively() {
        var s = TrackerState()
        s.apply([pr(1, events: [])], viewer: "Me")
        let fresh = s.apply([pr(1, events: [event("a", actor: "me"), event("b", actor: "ME")])], viewer: "Me")
        XCTAssertTrue(fresh.isEmpty)
    }

    func testMarkReadPerPRAndAll() {
        var s = TrackerState()
        s.apply([pr(1, events: []), pr(2, events: [])], viewer: "me")
        s.apply([pr(1, events: [event("a", pr: "o/r#1")]), pr(2, events: [event("b", pr: "o/r#2")])], viewer: "me")
        XCTAssertEqual(s.unread.count, 2)
        s.markRead(prKey: "o/r#1")
        XCTAssertEqual(s.unread.map(\.id), ["b"])
        s.markAllRead()
        XCTAssertTrue(s.unread.isEmpty)
    }

    func testClosedPRsPrunedAndRebaselinedIfReopened() {
        var s = TrackerState()
        s.apply([pr(1, events: [])], viewer: "me")
        s.apply([pr(1, events: [event("a")])], viewer: "me")
        XCTAssertEqual(s.unread.count, 1)
        s.apply([], viewer: "me")                                // PR gone
        XCTAssertTrue(s.unread.isEmpty)
        XCTAssertNil(s.known["o/r#1"])
        XCTAssertTrue(s.apply([pr(1, events: [event("a")])], viewer: "me").isEmpty)
    }

    func testStaleUnreadNoLongerInFetchIsDropped() {
        var s = TrackerState()
        s.apply([pr(1, events: [])], viewer: "me")
        s.apply([pr(1, events: [event("a"), event("b")])], viewer: "me")
        XCTAssertEqual(s.unread.count, 2)
        s.apply([pr(1, events: [event("b")])], viewer: "me")     // "a" is no longer reported
        XCTAssertEqual(s.unread.map(\.id), ["b"])
    }

    func testUnreadForSortedNewestFirst() {
        var s = TrackerState()
        s.apply([pr(1, events: [])], viewer: "me")
        s.apply([pr(1, events: [event("old", at: 1), event("new", at: 9)])], viewer: "me")
        XCTAssertEqual(s.unread(for: "o/r#1").map(\.id), ["new", "old"])
    }

    func testCodableRoundTrip() throws {
        var s = TrackerState()
        s.apply([pr(1, events: [])], viewer: "me")
        s.apply([pr(1, events: [event("a")])], viewer: "me")
        let back = try JSONDecoder().decode(TrackerState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
