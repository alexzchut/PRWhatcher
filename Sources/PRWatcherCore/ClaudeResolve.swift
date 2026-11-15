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
        export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd \(shellQuote(directory)) || { echo "Folder not found: "\(shellQuote(directory)); exit 1; }
        if ! command -v claude >/dev/null; then echo "Claude Code (claude) is not installed or not on PATH"; exit 1; fi
        claude \(shellQuote(prompt))

        """
    }

    /// Single-quotes `s` for zsh; embedded single quotes become `'\\''`.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
