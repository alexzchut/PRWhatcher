import Foundation

/// Builds the task handed to Claude Code when the user clicks Resolve on a PR: check out the PR locally,
/// address each unresolved review thread, push, reply to every thread and resolve the addressed ones.
public enum ClaudeResolve {
    public static func prompt(for pr: PullRequest) -> String {
        var lines = [
            "Resolve the open review comments on \(pr.url.absoluteString) (\(pr.repo) #\(pr.number): \"\(pr.title)\").",
            "",
            "Unresolved review threads (\(pr.unresolvedThreads.count)):",
        ]
        for (i, t) in pr.unresolvedThreads.enumerated() {
            var head = "\(i + 1). \(t.author)\(t.isCopilot ? " (Copilot)" : "")"
            if let path = t.path { head += " on \(path)" + (t.line.map { ":\($0)" } ?? "") }
            lines.append(head)
            lines.append("   thread id: \(t.id)")
            if let url = t.url { lines.append("   link: \(url.absoluteString)") }
            if !t.body.isEmpty {
                let flat = t.body.replacingOccurrences(of: "\n", with: " ")
                lines.append("   comment: \(flat)")
            }
        }
        lines += [
            "",
            "Steps:",
            "1. Confirm this folder is a checkout of \(pr.repo) (`gh repo view --json nameWithOwner`). Run `git status`; if there are uncommitted changes, stop and tell me instead of continuing.",
            "2. Check out the PR branch and update it: `gh pr checkout \(pr.number) && git pull`.",
            "3. For each thread, read the whole conversation and the code it points to. The comment text above is only the start of the thread. To read a thread in full:",
            "   gh api graphql -f query='query($id:ID!){node(id:$id){... on PullRequestReviewThread{path line isResolved comments(first:50){nodes{author{login} body url}}}}}' -f id=<thread id>",
            "4. Decide for each thread whether the code should change. Make the changes that are warranted; don't change code just to satisfy a comment you think is wrong.",
            "5. Run the project's build and tests if it has them, then commit with a clear message and push to the PR branch.",
            "6. Reply on every thread: what you changed (with the commit SHA), or why you left the code as it is.",
            "   gh api graphql -f query='mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){comment{url}}}' -f id=<thread id> -f body=<reply>",
            "7. Resolve each thread you fixed or answered conclusively. Leave a thread unresolved when it needs my decision, and say so in the reply.",
            "   gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread id>",
            "8. Finish with a short table: each thread, what you did (fixed / no change / needs my input), and whether it is resolved.",
        ]
        return lines.joined(separator: "\n")
    }

    /// A `.command` script that Terminal runs: starts an interactive Claude Code session in `directory`.
    /// The script deletes itself once started, so the prompt doesn't linger in the temp folder.
    public static func launchScript(directory: String, prompt: String) -> String {
        """
        #!/bin/zsh -l
        rm -f "$0"
        \(pathExport)
        cd \(shellQuote(directory)) || { echo "Folder not found: "\(shellQuote(directory)); exit 1; }
        if ! command -v claude >/dev/null; then echo "Claude Code (claude) is not installed or not on PATH"; exit 1; fi
        claude \(shellQuote(prompt))

        """
    }

    /// Where Claude Code's installers put `claude`; prepended to the login shell's PATH, since an app launched
    /// from Finder or at login doesn't inherit the PATH from the user's shell config.
    static let searchPath = "$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
    static var pathExport: String { "export PATH=\"\(searchPath)\"" }

    public enum CheckError: LocalizedError {
        case notFound
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .notFound: return "Claude Code (claude) isn't installed or isn't on your PATH. Install it from claude.com/claude-code."
            case .failed(let m): return "`claude --version` failed: \(m)"
            }
        }
    }

    /// Finds `claude` the same way the Terminal script does and runs `claude --version`, so enabling the
    /// feature fails early instead of on the first Resolve. Returns "<version> at <path>". No model call is made.
    public static func checkCLI() throws -> String { try checkCLI(pathExport: pathExport) }

    /// `pathExport` is replaceable so tests can point it at a stub.
    static func checkCLI(pathExport: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", """
            \(pathExport)
            bin=$(command -v claude) || exit 127
            ver=$("$bin" --version) || exit $?
            echo "PRW_BIN=$bin"
            echo "PRW_VER=$ver"
            """]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // A login shell's profile may print its own output; only the tagged lines count.
        func value(_ tag: String) -> String? {
            o.split(whereSeparator: \.isNewline).last { $0.hasPrefix(tag) }
                .map { $0.dropFirst(tag.count).trimmingCharacters(in: .whitespaces) }
        }
        if p.terminationStatus == 127 { throw CheckError.notFound }
        guard p.terminationStatus == 0, let bin = value("PRW_BIN="), let ver = value("PRW_VER=") else {
            let msg = e.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckError.failed(msg.isEmpty ? "exit code \(p.terminationStatus)" : msg)
        }
        return "\(ver) at \((bin as NSString).abbreviatingWithTildeInPath)"
    }

    /// Single-quotes `s` for zsh; embedded single quotes become `'\\''`.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
