import Foundation

/// Where Claude works on a PR's review fixes: a git worktree next to the user's checkout, on its own branch
/// started from the PR's branch, so the checkout's branch and uncommitted changes are never touched.
public struct ResolveWorkspace: Equatable {
    public let checkout: String     // the user's local clone
    public let worktree: String     // sibling folder, e.g. ~/code/zapp-pr-5092
    public let branch: String       // claude/<PR branch>, e.g. claude/feat/login
    public let base: String         // the PR's head branch; fixes are pushed back to it

    public init(checkout: String, prNumber: Int, base: String) {
        let url = URL(fileURLWithPath: checkout).standardizedFileURL
        self.checkout = url.path
        self.worktree = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-pr-\(prNumber)").path
        self.branch = "claude/\(base)"
        self.base = base
    }
}

/// Builds the task handed to Claude Code when the user clicks Resolve on a PR: work through each unresolved
/// review thread on a fix branch, push the fixes to the PR, reply to every thread and resolve the addressed ones.
public enum ClaudeResolve {
    public static func prompt(for pr: PullRequest, in ws: ResolveWorkspace) -> String {
        var lines = [
            "Resolve the open review comments on \(pr.url.absoluteString) (\(pr.repo) #\(pr.number): \"\(pr.title)\").",
            "",
            "You are in a git worktree made for this: \(ws.worktree), on branch `\(ws.branch)`, started from `origin/\(ws.base)` (the PR's branch). Do all the work here. Don't touch my main checkout at \(ws.checkout). Git-ignored files (node_modules, .env, build caches) were copied from my checkout when the worktree was created, so dependencies are already installed; reinstall only if the PR changes the dependency manifests or lockfile compared to my checkout.",
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
            "1. Confirm this is a checkout of \(pr.repo) (`gh repo view --json nameWithOwner`) and you're on `\(ws.branch)`. If this worktree is left over from an earlier run, check `git status` and `git log --oneline origin/\(ws.base)..HEAD`: if there are uncommitted changes or unpushed commits, stop and tell me. Otherwise bring it up to date with `git merge --ff-only origin/\(ws.base)`.",
            "2. For each thread, read the whole conversation and the code it points to. The comment text above is only the start of the thread. To read a thread in full:",
            "   gh api graphql -f query='query($id:ID!){node(id:$id){... on PullRequestReviewThread{path line isResolved comments(first:50){nodes{author{login} body url}}}}}' -f id=<thread id>",
            "3. Decide for each thread whether the code should change. Make the changes that are warranted; don't change code just to satisfy a comment you think is wrong.",
            "4. Before committing, run the `/simplify` skill on your changes, then the `/verify` skill, and fix what they find. If either skill isn't available, say so and do the equivalent yourself (simplify: review your diff for reuse and needless complexity; verify: run the project's build and tests and check the change works). Then commit on `\(ws.branch)` with a clear message.",
            "5. Push the fixes to the PR: `git push origin HEAD:\(ws.base)`. Never force-push. If the push is rejected because the PR branch moved, run `git fetch origin \(ws.base) && git rebase origin/\(ws.base)`, re-run the tests and push again.",
            "6. Reply on every thread: what you changed (with the commit SHA), or why you left the code as it is.",
            "   gh api graphql -f query='mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){comment{url}}}' -f id=<thread id> -f body=<reply>",
            "7. Resolve each thread you fixed or answered conclusively. Leave a thread unresolved when it needs my decision, and say so in the reply.",
            "   gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread id>",
            "8. Finish with a short table: each thread, what you did (fixed / no change / needs my input), and whether it is resolved. When this session ends, the worktree and the `\(ws.branch)` branch are removed automatically if everything is committed and pushed (otherwise they're kept), so don't remove them yourself.",
        ]
        return lines.joined(separator: "\n")
    }

    /// A `.command` script that the terminal runs: creates (or reuses) the PR's worktree on its fix branch,
    /// starts an interactive Claude Code session there, and removes the worktree and branch once the session
    /// ends with everything committed and pushed. The script deletes itself once started, so the prompt
    /// doesn't linger in the temp folder.
    public static func launchScript(_ ws: ResolveWorkspace, prompt: String) -> String {
        let checkout = shellQuote(ws.checkout), worktree = shellQuote(ws.worktree)
        let base = shellQuote(ws.base), branch = shellQuote(ws.branch), remoteBase = shellQuote("origin/" + ws.base)
        return """
        #!/bin/zsh -l
        rm -f "$0"
        \(pathExport)
        cd \(checkout) || { echo "Folder not found: "\(checkout); exit 1; }
        if ! command -v claude >/dev/null; then echo "Claude Code (claude) is not installed or not on PATH"; exit 1; fi
        git fetch origin \(base) || { echo "Couldn't fetch the PR branch "\(base); exit 1; }
        if [ -d \(worktree) ]; then
          echo "Reusing worktree "\(worktree)
        else
          git worktree prune
          git worktree add -B \(branch) \(worktree) \(remoteBase) || { echo "Couldn't create the worktree "\(worktree); exit 1; }
          # A worktree has only tracked files. Copy what git ignores (node_modules, .env, build caches) from the
          # checkout so nothing has to be reinstalled; APFS clones (cp -c) make this fast and take no extra space.
          echo "Copying dependencies and other ignored files from "\(checkout)
          git ls-files -z --others --ignored --exclude-standard --directory | while IFS= read -r -d "" p; do
            p=${p%/}
            [ -e \(worktree)/"$p" ] && continue
            mkdir -p \(worktree)/"$(dirname "$p")"
            cp -cR "$p" \(worktree)/"$p" 2>/dev/null || cp -R "$p" \(worktree)/"$p"
          done
        fi
        cd \(worktree) || exit 1
        claude \(shellQuote(prompt))

        # Session over: remove the worktree and its branch, unless that would lose work. Any failed check counts
        # as "keep".
        cd \(checkout) || exit 0
        git fetch -q origin \(base) 2>/dev/null
        dirty=$(git -C \(worktree) status --porcelain) || dirty=unknown
        unpushed=$(git -C \(worktree) log --oneline \(remoteBase)..HEAD) || unpushed=unknown
        if [ -n "$dirty" ]; then
          echo "Kept the worktree "\(worktree)" and branch "\(branch)": it has uncommitted changes."
        elif [ -n "$unpushed" ]; then
          echo "Kept the worktree "\(worktree)" and branch "\(branch)": it has commits not pushed to the PR."
        else
          git worktree remove --force \(worktree) && git branch -q -D \(branch) &&
            echo "Removed the worktree "\(worktree)" and branch "\(branch)"."
        fi

        """
    }

    public static let iTermBundleID = "com.googlecode.iterm2"

    /// AppleScript that runs `script` in iTerm2, typed into the user's shell so the session stays open after
    /// Claude exits. Opens a new tab in the front window when iTerm2 already has one; a new window otherwise.
    /// If iTerm2 wasn't running, the window it opens on launch is used.
    public static func iTermAppleScript(running script: String) -> String {
        let command = shellQuote(script)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        set wasRunning to application id "\(iTermBundleID)" is running
        tell application id "\(iTermBundleID)"
            activate
            if (count of windows) = 0 then
                set w to (create window with default profile)
            else if wasRunning then
                set w to current window
                tell w to create tab with default profile
            else
                set w to current window
            end if
            tell current session of w to write text "\(command)"
        end tell
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
