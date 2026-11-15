import AppKit
import PRWatcherCore

/// Opens a Terminal window running Claude Code in the PR's local checkout, with a prompt to work through
/// the PR's unresolved review threads.
@MainActor
enum ClaudeLauncher {
    /// True while the folder picker is up; the panel closes for it and keeps its Settings page for when it reopens.
    static private(set) var isPicking = false

    enum Outcome: Equatable {
        case launched
        /// The repo has no usable local checkout yet; the user sets it in Settings → Repositories.
        case needsFolder
        case failed(String)
    }

    static func resolve(_ pr: PullRequest, store: Store) -> Outcome {
        guard !pr.unresolvedThreads.isEmpty else { return .failed("No unresolved review threads on #\(pr.number)") }
        guard let folder = store.localPath(for: pr.repo), isGitCheckout(folder) else {
            store.setLocalPath(nil, for: pr.repo)     // forget a folder that moved or is no longer a checkout
            return .needsFolder
        }
        guard let base = pr.headRef else { return .failed("Couldn't read the branch of #\(pr.number); refresh and try again") }
        let ws = ResolveWorkspace(checkout: folder, prNumber: pr.number, base: base)
        if let error = open(ws, prompt: ClaudeResolve.prompt(for: pr, in: ws)) { return .failed(error) }
        return .launched
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

    /// Writes the launch script and runs it in iTerm2 when installed, otherwise in Terminal.
    private static func open(_ ws: ResolveWorkspace, prompt: String) -> String? {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("prwatcher-resolve-\(UUID().uuidString).command")
        do {
            try ClaudeResolve.launchScript(ws, prompt: prompt)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return "Couldn't write the launch script: \(error.localizedDescription)"
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeResolve.iTermBundleID) != nil {
            openInITerm(script)
            return nil
        }
        return openInTerminal(script)
    }

    /// Runs off the main thread: launching iTerm2 and the one-time automation permission prompt can take a while.
    /// Falls back to Terminal if iTerm2 can't be driven (for example, automation permission was denied).
    private static func openInITerm(_ script: URL) {
        let source = ClaudeResolve.iTermAppleScript(running: script.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            if !ok { DispatchQueue.main.async { _ = openInTerminal(script) } }
        }
    }

    @discardableResult
    private static func openInTerminal(_ script: URL) -> String? {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return "Terminal.app not found"
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }
}
