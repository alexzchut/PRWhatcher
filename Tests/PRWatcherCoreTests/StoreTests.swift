import XCTest
@testable import PRWatcherCore

final class FakeFetcher: PRFetching {
    var results: [Result<FetchResult, Error>] = []
    var calls = 0
    var lastRepos: [String] = []
    func fetch(repos: [String]) async throws -> FetchResult {
        calls += 1; lastRepos = repos
        return try results.removeFirst().get()
    }
}

final class FakeNotifier: Notifying {
    var sent: [(title: String, body: String, url: URL?)] = []
    func notify(title: String, body: String, url: URL?) { sent.append((title, body, url)) }
}

@MainActor
final class StoreTests: XCTestCase {
    var dir: URL!
    var suite: String!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "test-\(UUID().uuidString)"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func make(_ f: FakeFetcher, _ n: FakeNotifier) -> Store {
        Store(fetcher: f, notifier: n, defaults: UserDefaults(suiteName: suite)!,
              stateURL: dir.appendingPathComponent("state.json"))
    }
    private func ok(_ events: [ActivityEvent]) -> Result<FetchResult, Error> {
        .success(FetchResult(viewer: "me", pullRequests: [pr(1, events: events)]))
    }

    func testDefaults() {
        let s = make(FakeFetcher(), FakeNotifier())
        XCTAssertEqual(s.intervalMinutes, 5)
        XCTAssertTrue(s.repos.isEmpty)
    }

    func testRepoManagement() {
        let s = make(FakeFetcher(), FakeNotifier())
        XCTAssertTrue(s.addRepo(" o/r "))
        XCTAssertFalse(s.addRepo("O/R"))        // duplicate, case-insensitive
        XCTAssertFalse(s.addRepo("nope"))
        XCTAssertEqual(s.repos, ["o/r"])
        s.removeRepo("o/r")
        XCTAssertTrue(s.repos.isEmpty)
    }

    func testNormalizeRepoAcceptsURLs() {
        let want = "applicaster/gold-customers"
        for input in ["https://github.com/applicaster/gold-customers", "https://github.com/applicaster/gold-customers/",
                      "github.com/applicaster/gold-customers.git", "git@github.com:applicaster/gold-customers.git",
                      "https://github.com/applicaster/gold-customers/pull/12", " applicaster/gold-customers "] {
            XCTAssertEqual(Store.normalizeRepo(input), want, input)
        }
        XCTAssertEqual(Store.normalizeRepo("nope"), "nope")
    }

    func testAddRepoFromURL() {
        let s = make(FakeFetcher(), FakeNotifier())
        XCTAssertTrue(s.addRepo("https://github.com/applicaster/gold-customers"))
        XCTAssertEqual(s.repos, ["applicaster/gold-customers"])
    }

    func testSettingsPersistAndIntervalClamped() {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        _ = s.addRepo("o/r")
        s.intervalMinutes = 15
        XCTAssertEqual(make(f, n).repos, ["o/r"])
        XCTAssertEqual(make(f, n).intervalMinutes, 15)
        s.intervalMinutes = 500
        XCTAssertEqual(s.intervalMinutes, 60)
        s.intervalMinutes = 0
        XCTAssertEqual(s.intervalMinutes, 1)
    }

    func testRefreshWithoutReposDoesNotFetch() async {
        let f = FakeFetcher()
        let s = make(f, FakeNotifier())
        await s.refresh()
        XCTAssertEqual(f.calls, 0)
        XCTAssertEqual(s.status, "Add a repository in Settings")
    }

    func testBaselineThenNotifyOnNewActivity() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        _ = s.addRepo("o/r")
        f.results = [ok([event("a")]),
                     ok([event("a"), event("b", actor: "bob", at: 5), event("c", kind: .commit, actor: "bob", at: 6),
                         event("m", actor: "me", at: 7)])]
        await s.refresh()
        XCTAssertTrue(n.sent.isEmpty)
        XCTAssertEqual(s.unreadCount, 0)
        XCTAssertEqual(f.lastRepos, ["o/r"])
        XCTAssertNotNil(s.lastChecked)

        await s.refresh()
        XCTAssertEqual(n.sent.count, 1)
        XCTAssertEqual(n.sent[0].title, "o/r #1")
        XCTAssertTrue(n.sent[0].body.contains("1 comment, 1 commit"))
        XCTAssertTrue(n.sent[0].body.contains("bob"))
        XCTAssertEqual(s.unreadCount, 2)
    }

    func testMarkReadAndPersistenceAcrossLaunches() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        _ = s.addRepo("o/r")
        f.results = [ok([]), ok([event("b", actor: "bob")])]
        await s.refresh(); await s.refresh()
        XCTAssertEqual(s.unreadCount, 1)

        let reopened = make(f, n)
        XCTAssertEqual(reopened.unreadCount, 1)             // restored from disk
        reopened.markRead(s.pullRequests[0])
        XCTAssertEqual(make(f, n).unreadCount, 0)

        s.markAllRead()
        XCTAssertEqual(s.unreadCount, 0)
    }

    func testErrorSetsStatusAndKeepsState() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        _ = s.addRepo("o/r")
        f.results = [ok([]), .failure(Boom()), ok([])]
        await s.refresh()
        await s.refresh()
        XCTAssertEqual(s.status, "boom")
        XCTAssertEqual(s.pullRequests.count, 1)
        await s.refresh()
        XCTAssertEqual(s.status, "")
        XCTAssertFalse(s.isRefreshing)
    }

    func testPollingRefreshesImmediatelyAndStops() async throws {
        let f = FakeFetcher()
        f.results = [ok([])]
        let s = make(f, FakeNotifier())
        _ = s.addRepo("o/r")
        s.startPolling()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.calls, 1)
        s.stopPolling()
    }
}
