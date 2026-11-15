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

    func testParsesHeadRef() throws {
        let json = #"{"data":{"viewer":{"login":"me"},"search":{"nodes":[{"number":1,"title":"t","url":"https://github.com/o/r/pull/1","headRefName":"feat/x","repository":{"nameWithOwner":"o/r"}}]}}}"#
        XCTAssertEqual(try GitHubClient.parse(json.data(using: .utf8)!).pullRequests[0].headRef, "feat/x")
        XCTAssertTrue(GitHubClient.fragment.contains("headRefName"))
    }

    func testWorkspaceIsASiblingWorktreeOnAFixBranch() {
        let ws = ResolveWorkspace(checkout: "/Users/me/code/zapp/", prNumber: 5092, base: "feat/x")
        XCTAssertEqual(ws.checkout, "/Users/me/code/zapp")
        XCTAssertEqual(ws.worktree, "/Users/me/code/zapp-pr-5092")
        XCTAssertEqual(ws.branch, "pr-5092-review-fixes")
        XCTAssertEqual(ws.base, "feat/x")
    }

    func testPromptListsEveryThreadAndTheSteps() {
        let pr = PullRequest(repo: "o/r", number: 7, title: "Add thing",
                             url: URL(string: "https://github.com/o/r/pull/7")!, events: [],
                             unresolvedThreads: [
                                ReviewThread(id: "PRRT_a", author: "alice", path: "a.swift", line: 3,
                                             url: URL(string: "https://github.com/o/r/pull/7#discussion_r1"),
                                             body: "rename\nthis"),
                                ReviewThread(id: "PRRT_b", author: "Copilot", body: "null check"),
                             ], headRef: "feat/x")
        let ws = ResolveWorkspace(checkout: "/c/r", prNumber: 7, base: "feat/x")
        let p = ClaudeResolve.prompt(for: pr, in: ws)
        XCTAssertTrue(p.contains("https://github.com/o/r/pull/7"))
        XCTAssertTrue(p.contains("1. alice on a.swift:3"))
        XCTAssertTrue(p.contains("thread id: PRRT_a"))
        XCTAssertTrue(p.contains("link: https://github.com/o/r/pull/7#discussion_r1"))
        XCTAssertTrue(p.contains("comment: rename this"))
        XCTAssertTrue(p.contains("2. Copilot (Copilot)"))
        XCTAssertTrue(p.contains("git worktree made for this: /c/r-pr-7, on branch `pr-7-review-fixes`"))
        XCTAssertTrue(p.contains("Don't touch my main checkout at /c/r"))
        XCTAssertTrue(p.contains("git push origin HEAD:feat/x"))
        XCTAssertTrue(p.contains("Never force-push"))
        XCTAssertFalse(p.contains("gh pr checkout"))
        XCTAssertTrue(p.contains("addPullRequestReviewThreadReply"))
        XCTAssertTrue(p.contains("resolveReviewThread"))
    }

    func testShellQuote() {
        XCTAssertEqual(ClaudeResolve.shellQuote("a b"), "'a b'")
        XCTAssertEqual(ClaudeResolve.shellQuote("it's"), #"'it'\''s'"#)
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String], in dir: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func git(_ args: String..., in dir: URL) throws {
        let status = try run("/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"] + args, in: dir)
        XCTAssertEqual(status, 0, "git \(args.joined(separator: " "))")
    }

    /// Runs the generated script under zsh against a real local "origin" with a stub `claude`: the worktree is
    /// created on the fix branch from the PR branch, reused on a second run, the user's checkout stays on its
    /// branch, and the prompt arrives intact.
    func testLaunchScriptCreatesWorktreeAndPassesPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        let bin = tmp.appendingPathComponent("bin"), origin = tmp.appendingPathComponent("origin")
        let checkout = tmp.appendingPathComponent("my repo")
        for d in [bin, origin] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: tmp) }

        try git("init", "-q", in: origin)
        try git("commit", "-q", "--allow-empty", "-m", "base", in: origin)
        try git("checkout", "-q", "-b", "feat/x", in: origin)
        try git("commit", "-q", "--allow-empty", "-m", "pr work", in: origin)
        try git("checkout", "-q", "main", in: origin)
        try git("clone", "-q", origin.path, checkout.path, in: tmp)

        let out = tmp.appendingPathComponent("out.txt")
        let stub = bin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        pwd > '\(out.path)'
        git branch --show-current >> '\(out.path)'
        git log -1 --format=%s >> '\(out.path)'
        printf '%s' "$1" >> '\(out.path)'

        """.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let ws = ResolveWorkspace(checkout: checkout.path, prNumber: 7, base: "feat/x")
        let prompt = "it's \"quoted\" $HOME `x`\nline 2"
        func launch() throws -> [String] {
            let script = tmp.appendingPathComponent("run.command")
            // Swap the script's PATH line so only the stub can be found, never a real installed `claude`.
            let lines = ClaudeResolve.launchScript(ws, prompt: prompt)
                .components(separatedBy: "\n")
                .map { $0.hasPrefix("export PATH=") ? "export PATH=\"\(bin.path):/usr/bin:/bin\"" : $0 }
            XCTAssertTrue(lines.contains("export PATH=\"\(bin.path):/usr/bin:/bin\""))
            try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
            XCTAssertEqual(try run("/bin/zsh", ["-f", script.path]), 0)
            XCTAssertFalse(fm.fileExists(atPath: script.path), "script removes itself")
            return try String(contentsOf: out, encoding: .utf8).components(separatedBy: "\n")
        }

        for _ in 0..<2 {      // second run reuses the existing worktree
            let o = try launch()
            XCTAssertTrue(o[0].hasSuffix("/my repo-pr-7"), o[0])
            XCTAssertEqual(o[1], "pr-7-review-fixes")
            XCTAssertEqual(o[2], "pr work")
            XCTAssertEqual(o.dropFirst(3).joined(separator: "\n"), prompt)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", checkout.path, "branch", "--show-current"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "main\n",
                       "the user's checkout stays on its branch")
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
        XCTAssertTrue(ClaudeResolve.launchScript(ResolveWorkspace(checkout: "/x", prNumber: 1, base: "b"), prompt: "p").contains(ClaudeResolve.pathExport))
    }

    func testITermScriptQuotesThePath() {
        let src = ClaudeResolve.iTermAppleScript(running: #"/tmp/a b/it's "x".command"#)
        XCTAssertTrue(src.contains(#"application id "com.googlecode.iterm2""#))
        XCTAssertTrue(src.contains("create window with default profile"))
        XCTAssertTrue(src.contains("create tab with default profile"))
        // shell-quoted, then escaped for an AppleScript string literal
        XCTAssertTrue(src.contains(#"write text "'/tmp/a b/it'\\''s \"x\".command'""#), src)
    }

    /// The generated AppleScript must at least compile (osacompile doesn't need iTerm2 to run).
    func testITermScriptCompiles() throws {
        // Compiling needs iTerm2's scripting dictionary.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/Applications/iTerm.app"), "iTerm2 not installed")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scpt")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        p.arguments = ["-o", out.path, "-e", ClaudeResolve.iTermAppleScript(running: "/tmp/x.command")]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}
