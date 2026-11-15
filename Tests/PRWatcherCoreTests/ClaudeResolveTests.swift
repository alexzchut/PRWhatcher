import XCTest
@testable import PRWatcherCore

final class ClaudeResolveTests: XCTestCase {
    private func thread(_ id: String?, author: String, resolved: Bool, path: String? = "src/a.swift",
                        line: Int? = 12, body: String = "please fix") -> String {
        let idField = id.map { #""id":"\#($0)","# } ?? ""
        let pathField = path.map { #""path":"\#($0)","# } ?? ""
        let lineField = line.map { #""line":\#($0),"# } ?? ""
        return #"{\#(idField)\#(pathField)\#(lineField)"isResolved":\#(resolved),"root":{"nodes":[{"id":"c","url":"https://github.com/o/r/pull/1#discussion_r\#(id ?? "x")","bodyText":"\#(body)","author":{"login":"\#(author)"}}]},"comments":{"nodes":[]}}"#
    }

    private func parse(_ threads: [String]) throws -> PullRequest {
        let json = """
        {"data":{"viewer":{"login":"me"},"search":{"nodes":[{"number":1,"title":"Fix it","url":"https://github.com/o/r/pull/1",
        "repository":{"nameWithOwner":"o/r"},"reviewThreads":{"nodes":[\(threads.joined(separator: ","))]}}]}}}
        """
        return try GitHubClient.parse(json.data(using: .utf8)!).pullRequests[0]
    }

    func testQueryRequestsThreadIds() {
        XCTAssertTrue(GitHubClient.fragment.contains("id isResolved path line"))
    }

    func testUnresolvedThreadsExcludeResolvedAndOwn() throws {
        let pr = try parse([
            thread("T1", author: "alice", resolved: false),
            thread("T2", author: "alice", resolved: true),
            thread("T3", author: "me", resolved: false),
            thread("T4", author: "copilot-pull-request-reviewer", resolved: false, path: nil, line: nil),
            thread(nil, author: "bob", resolved: false),          // no id: can't be resolved, skipped
        ])
        XCTAssertEqual(pr.unresolvedThreads.map(\.id), ["T1", "T4"])
        let t = pr.unresolvedThreads[0]
        XCTAssertEqual(t.author, "alice")
        XCTAssertEqual(t.path, "src/a.swift")
        XCTAssertEqual(t.line, 12)
        XCTAssertEqual(t.body, "please fix")
        XCTAssertEqual(t.url?.absoluteString, "https://github.com/o/r/pull/1#discussion_rT1")
        XCTAssertTrue(pr.unresolvedThreads[1].isCopilot)
    }

    func testPromptListsEveryThreadAndTheSteps() {
        let pr = PullRequest(repo: "o/r", number: 7, title: "Add thing",
                             url: URL(string: "https://github.com/o/r/pull/7")!, events: [],
                             unresolvedThreads: [
                                ReviewThread(id: "PRRT_a", author: "alice", path: "a.swift", line: 3,
                                             url: URL(string: "https://github.com/o/r/pull/7#discussion_r1"),
                                             body: "rename\nthis"),
                                ReviewThread(id: "PRRT_b", author: "Copilot", body: "null check"),
                             ])
        let p = ClaudeResolve.prompt(for: pr)
        XCTAssertTrue(p.contains("https://github.com/o/r/pull/7"))
        XCTAssertTrue(p.contains("1. alice on a.swift:3"))
        XCTAssertTrue(p.contains("thread id: PRRT_a"))
        XCTAssertTrue(p.contains("link: https://github.com/o/r/pull/7#discussion_r1"))
        XCTAssertTrue(p.contains("comment: rename this"))
        XCTAssertTrue(p.contains("2. Copilot (Copilot)"))
        XCTAssertTrue(p.contains("gh pr checkout 7"))
        XCTAssertTrue(p.contains("addPullRequestReviewThreadReply"))
        XCTAssertTrue(p.contains("resolveReviewThread"))
        XCTAssertTrue(p.contains("uncommitted changes, stop"))
    }

    func testShellQuote() {
        XCTAssertEqual(ClaudeResolve.shellQuote("a b"), "'a b'")
        XCTAssertEqual(ClaudeResolve.shellQuote("it's"), #"'it'\''s'"#)
    }

    /// Runs the generated script under zsh with a stub `claude` to check the prompt arrives intact.
    func testLaunchScriptPassesPromptVerbatim() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = tmp.appendingPathComponent("bin"), work = tmp.appendingPathComponent("my repo")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out = tmp.appendingPathComponent("out.txt")
        let stub = bin.appendingPathComponent("claude")
        try "#!/bin/sh\npwd > '\(out.path)'\nprintf '%s' \"$1\" >> '\(out.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let prompt = "it's \"quoted\" $HOME `x`\nline 2"
        let script = tmp.appendingPathComponent("run.command")
        // Swap the script's PATH line so only the stub can be found, never a real installed `claude`.
        let lines = ClaudeResolve.launchScript(directory: work.path, prompt: prompt)
            .components(separatedBy: "\n")
            .map { $0.hasPrefix("export PATH=") ? "export PATH=\"\(bin.path):/usr/bin:/bin\"" : $0 }
        XCTAssertTrue(lines.contains("export PATH=\"\(bin.path):/usr/bin:/bin\""))
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", script.path]
        try p.run()
        p.waitUntilExit()

        XCTAssertEqual(p.terminationStatus, 0)
        let output = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(output.hasSuffix(prompt))
        XCTAssertTrue(output.contains("my repo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path), "script removes itself")
    }

    // MARK: - CLI check (stubs only; a real `claude` is never on the test PATH)

    private func stubDir(claude script: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let script {
            let stub = dir.appendingPathComponent("claude")
            try ("#!/bin/sh\n" + script).write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        return dir
    }

    private func check(_ dir: URL) throws -> String {
        try ClaudeResolve.checkCLI(pathExport: "export PATH=\"\(dir.path):/usr/bin:/bin\"")
    }

    func testCheckReportsVersionAndPath() throws {
        let dir = try stubDir(claude: "echo '2.1.325 (Claude Code)'\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try check(dir)
        XCTAssertTrue(found.hasPrefix("2.1.325 (Claude Code) at "), found)
        XCTAssertTrue(found.hasSuffix("/claude"), found)
    }

    func testCheckFailsWhenNotInstalled() throws {
        let dir = try stubDir(claude: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try check(dir)) { error in
            guard case ClaudeResolve.CheckError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    func testCheckFailsWhenClaudeErrors() throws {
        let dir = try stubDir(claude: "echo 'broken install' >&2\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try check(dir)) { error in
            guard case ClaudeResolve.CheckError.failed(let m) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(m, "broken install")
        }
    }

    func testLaunchScriptUsesSamePathAsCheck() {
        XCTAssertTrue(ClaudeResolve.launchScript(directory: "/x", prompt: "p").contains(ClaudeResolve.pathExport))
    }
}
