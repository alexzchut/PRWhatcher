import XCTest
@testable import PRWatcherCore

final class FakeFetcher: PRFetching {
    var results: [Result<FetchResult, Error>] = []
    var calls = 0
    var lastRepos: [String] = []
    var lastCustom: [PRRef] = []
    func fetch(repos: [String], custom: [PRRef]) async throws -> FetchResult {
        calls += 1; lastRepos = repos; lastCustom = custom
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

    func testAssignedListIsStoredWithoutAlerts() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        _ = s.addRepo("o/r")
        f.results = [.success(FetchResult(viewer: "me", pullRequests: [],
                                          assigned: [pr(5, events: [event("a", pr: "o/r#5")])]))]
        await s.refresh()
        XCTAssertEqual(s.assigned.map(\.key), ["o/r#5"])
        XCTAssertTrue(n.sent.isEmpty)
        XCTAssertEqual(s.unreadCount, 0)
    }

    func testCustomPRsAddRemovePersist() {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        XCTAssertTrue(s.addCustomPR("https://github.com/applicaster/zapp/pull/5052"))
        XCTAssertFalse(s.addCustomPR("applicaster/zapp#5052"))          // duplicate
        XCTAssertFalse(s.addCustomPR("not a pr"))
        XCTAssertEqual(s.customRefs.map(\.key), ["applicaster/zapp#5052"])
        XCTAssertEqual(make(f, n).customRefs.map(\.key), ["applicaster/zapp#5052"])   // persisted
        s.removeCustomPR(s.customRefs[0])
        XCTAssertTrue(s.customRefs.isEmpty)
        XCTAssertTrue(make(f, n).customRefs.isEmpty)
    }

    func testCustomPRsAreFetchedWithoutWatchedRepos() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        s.addCustomPR("o/r#7")
        f.results = [.success(FetchResult(viewer: "me", pullRequests: [], custom: [pr(7, events: [event("a", pr: "o/r#7")])]))]
        await s.refresh()
        XCTAssertEqual(f.calls, 1)
        XCTAssertEqual(f.lastCustom.map(\.key), ["o/r#7"])
        XCTAssertEqual(s.custom.map(\.key), ["o/r#7"])
        XCTAssertEqual(s.status, "")
    }

    func testCustomPRsAlertLikeOthersAndDedupeWithOwn() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        _ = s.addRepo("o/r")
        s.addCustomPR("o/r#1")        // also one of mine
        s.addCustomPR("x/y#2")
        func result(_ extra: [ActivityEvent]) -> Result<FetchResult, Error> {
            .success(FetchResult(viewer: "me",
                                 pullRequests: [pr(1, events: [])],
                                 custom: [pr(1, events: []), pr(2, repo: "x/y", events: extra)]))
        }
        f.results = [result([]), result([event("n", pr: "x/y#2", actor: "bob")])]
        await s.refresh()
        XCTAssertTrue(n.sent.isEmpty)                       // baseline
        await s.refresh()
        XCTAssertEqual(n.sent.map(\.title), ["x/y #2"])
        XCTAssertEqual(s.unreadCount, 1)
    }

    func testRemovingCustomPRForgetsItsState() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        s.addCustomPR("x/y#2")
        func result(_ e: [ActivityEvent]) -> Result<FetchResult, Error> {
            .success(FetchResult(viewer: "me", pullRequests: [], custom: [pr(2, repo: "x/y", events: e)]))
        }
        f.results = [result([]), result([event("n", pr: "x/y#2", actor: "bob")])]
        await s.refresh(); await s.refresh()
        XCTAssertEqual(s.unreadCount, 1)
        s.removeCustomPR(s.customRefs[0])
        XCTAssertEqual(s.unreadCount, 0)
        XCTAssertTrue(s.custom.isEmpty)
    }

    func testNewCustomPRIsLoadingUntilFetchedThenCheckedEvenIfMissing() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        s.addCustomPR("o/r#1")
        f.results = [.success(FetchResult(viewer: "me", pullRequests: [], custom: [pr(1, events: [])]))]
        await s.refresh()
        XCTAssertEqual(s.checkedCustom, ["o/r#1"])
        s.addCustomPR("o/r#2")
        XCTAssertFalse(s.checkedCustom.contains("o/r#2"))               // added after the last fetch: still loading
        f.results = [.success(FetchResult(viewer: "me", pullRequests: [], custom: [pr(1, events: [])]))]   // #2 missing
        await s.refresh()
        XCTAssertTrue(s.checkedCustom.contains("o/r#2"))
        XCTAssertEqual(s.custom.map(\.key), ["o/r#1"])                  // so #2 is genuinely not found
    }

    func testRefreshRequestedDuringFetchRunsAgain() async throws {
        final class SlowFetcher: PRFetching {
            var calls = 0
            var lastCustom: [PRRef] = []
            func fetch(repos: [String], custom: [PRRef]) async throws -> FetchResult {
                calls += 1; lastCustom = custom
                try await Task.sleep(nanoseconds: 150_000_000)
                return FetchResult(viewer: "me", pullRequests: [])
            }
        }
        let f = SlowFetcher()
        let s = Store(fetcher: f, notifier: FakeNotifier(), defaults: UserDefaults(suiteName: suite)!,
                      stateURL: dir.appendingPathComponent("state.json"))
        _ = s.addRepo("o/r")
        let first = Task { await s.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        s.addCustomPR("o/r#9")
        await s.refresh()                 // arrives mid-fetch
        await first.value
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(f.calls, 2)
        XCTAssertEqual(f.lastCustom.map(\.key), ["o/r#9"])
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

    func testCopilotOpenCountClearsWhenPanelOpenedAndReturnsForNewThreads() async {
        let f = FakeFetcher(), n = FakeNotifier()
        let s = make(f, n)
        s.addRepo("o/r")
        func result(_ open: Int) -> Result<FetchResult, Error> {
            let p = PullRequest(repo: "o/r", number: 1, title: "T1", url: URL(string: "https://github.com/o/r/pull/1")!,
                                events: [], review: ReviewSummary(copilotReviewed: true, copilotUnresolved: open))
            return .success(FetchResult(viewer: "me", pullRequests: [p]))
        }
        f.results = [result(11), result(11), result(13)]
        await s.refresh()
        XCTAssertEqual(s.menuBadgeCount, 11)
        s.markAllRead()                                     // what opening the panel does
        XCTAssertEqual(s.menuBadgeCount, 0)
        await s.refresh()
        XCTAssertEqual(s.menuBadgeCount, 0)
        await s.refresh()
        XCTAssertEqual(s.menuBadgeCount, 2)                 // two new threads since the panel was opened
    }
}
