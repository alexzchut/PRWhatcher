import AppKit
import PRWatcherCore

/// Opens a Terminal window running Claude Code in the PR's local checkout, with a prompt to work through
/// the PR's unresolved review threads.
@MainActor
enum ClaudeLauncher {
    /// True while the folder picker is up; the panel closes for it and keeps its Settings page for when it reopens.
    static private(set) var isPicking = false

    /// Calls `done` with an error message, or nil when Terminal was opened (or the folder picker was cancelled).
    static func resolve(_ pr: PullRequest, store: Store, done: @escaping @MainActor (String?) -> Void) {
        guard !pr.unresolvedThreads.isEmpty else { return done("No unresolved review threads on #\(pr.number)") }
        if let folder = store.localPath(for: pr.repo), isGitCheckout(folder) {
            return done(open(directory: folder, prompt: ClaudeResolve.prompt(for: pr)))
        }
        store.setLocalPath(nil, for: pr.repo)     // forget a folder that moved or is no longer a checkout
        chooseFolder(for: pr.repo) { picked in
            // On success Terminal takes focus; otherwise bring the panel back to show what happened.
            @MainActor func fail(_ message: String?) { reopenPanel(); done(message) }
            guard let picked else { return fail(nil) }
            guard isGitCheckout(picked) else { return fail("\(picked) is not a git checkout") }
            store.setLocalPath(picked, for: pr.repo)
            if let error = open(directory: picked, prompt: ClaudeResolve.prompt(for: pr)) { return fail(error) }
            done(nil)
        }
    }

    /// Lets the user pick the checkout folder for `repo`; `done` gets nil when cancelled.
    static func chooseFolder(for repo: String, done: @escaping @MainActor (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your local checkout of \(repo)"
        // The menu bar panel floats above normal windows (a picker opens behind it) and closes itself when it
        // loses focus (a sheet on it is left stranded). Close it first and show the picker on its own.
        isPicking = true
        if let host = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            if let sheet = host.attachedSheet { host.endSheet(sheet) }
            host.close()
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let path = panel.runModal() == .OK ? panel.url?.path : nil
            isPicking = false
            done(path)
        }
    }

    /// Reopens the menu bar panel the way a click on the menu bar icon does.
    static func reopenPanel() {
        DispatchQueue.main.async {
            for w in NSApp.windows {
                if let button = statusButton(in: w.contentView) { button.performClick(nil); return }
            }
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for v in view.subviews { if let b = statusButton(in: v) { return b } }
        return nil
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
