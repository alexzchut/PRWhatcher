import AppKit
import PRWatcherCore

/// Opens a Terminal window running Claude Code in the PR's local checkout, with a prompt to work through
/// the PR's unresolved review threads.
@MainActor
enum ClaudeLauncher {
    /// Returns an error message, or nil when Terminal was opened (or the user cancelled the folder picker).
    static func resolve(_ pr: PullRequest, store: Store) -> String? {
        guard !pr.unresolvedThreads.isEmpty else { return "No unresolved review threads on #\(pr.number)" }
        var folder = store.localPath(for: pr.repo)
        if let f = folder, !isGitCheckout(f) {
            store.setLocalPath(nil, for: pr.repo)
            folder = nil
        }
        if folder == nil {
            guard let picked = chooseFolder(for: pr.repo) else { return nil }
            guard isGitCheckout(picked) else { return "\(picked) is not a git checkout" }
            store.setLocalPath(picked, for: pr.repo)
            folder = picked
        }
        guard let folder else { return nil }
        return open(directory: folder, prompt: ClaudeResolve.prompt(for: pr))
    }

    /// Lets the user pick the checkout folder for `repo`. Returns nil when cancelled.
    static func chooseFolder(for repo: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your local checkout of \(repo)"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func isGitCheckout(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    private static func open(directory: String, prompt: String) -> String? {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("prwatcher-resolve-\(UUID().uuidString).command")
        do {
            try ClaudeResolve.launchScript(directory: directory, prompt: prompt)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return "Couldn't write the launch script: \(error.localizedDescription)"
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return "Terminal.app not found"
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }
}
