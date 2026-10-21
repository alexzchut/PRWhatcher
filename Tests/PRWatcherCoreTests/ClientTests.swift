import XCTest
@testable import PRWatcherCore

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.handler!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClientTests: XCTestCase {
    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    func testFetchSendsAuthAndSearchQuery() async throws {
        var seen: URLRequest?
        var body: Data?
        MockURLProtocol.handler = { req in
            seen = req
            body = req.httpBodyStream.map { s in
                s.open(); defer { s.close() }
                var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n <= 0 { break }; d.append(buf, count: n) }
                return d
            }
            return (200, sampleJSON)
        }
        let client = GitHubClient(session: session(), tokenProvider: { "tok" })
        let r = try await client.fetch(repos: ["o/r", "o/s"])
        XCTAssertEqual(r.pullRequests.count, 1)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "bearer tok")
        XCTAssertEqual(seen?.url?.absoluteString, "https://api.github.com/graphql")
        let text = String(decoding: body ?? Data(), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(text.contains("is:pr is:open draft:false author:@me repo:o/r repo:o/s"))
        XCTAssertTrue(text.contains("is:pr is:open draft:false assignee:@me -author:@me repo:o/r repo:o/s"))
        XCTAssertTrue(text.contains("is:pr is:open draft:false user-review-requested:@me -author:@me repo:o/r repo:o/s"))
    }

    func testRetriesOnceOn401WithFreshToken() async throws {
        var calls = 0
        var tokens = ["old", "new"]
        MockURLProtocol.handler = { req in
            calls += 1
            return req.value(forHTTPHeaderField: "Authorization") == "bearer new" ? (200, sampleJSON) : (401, Data())
        }
        let client = GitHubClient(session: session(), tokenProvider: { tokens.removeFirst() })
        _ = try await client.fetch(repos: ["o/r"])
        XCTAssertEqual(calls, 2)
    }

    func testHttpErrorSurfaces() async {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let client = GitHubClient(session: session(), tokenProvider: { "t" })
        do { _ = try await client.fetch(repos: ["o/r"]); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "GitHub HTTP 500") }
    }

    func testInvalidRepoRejectedBeforeNetwork() async {
        MockURLProtocol.handler = { _ in XCTFail("no request expected"); return (200, Data()) }
        let client = GitHubClient(session: session(), tokenProvider: { "t" })
        do { _ = try await client.fetch(repos: ["bad"]); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "Invalid repo “bad” (use owner/name)") }
    }

    func testTokenFailurePropagates() async {
        struct E: Error {}
        let client = GitHubClient(session: session(), tokenProvider: { throw E() })
        do { _ = try await client.fetch(repos: ["o/r"]); XCTFail() } catch { XCTAssertTrue(error is E) }
    }

    func testViewerLogin() async throws {
        MockURLProtocol.handler = { _ in (200, sampleJSON) }
        let client = GitHubClient(session: session(), tokenProvider: { "t" })
        let login = try await client.viewerLogin()
        XCTAssertEqual(login, "me")
    }
}
