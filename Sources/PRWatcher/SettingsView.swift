import SwiftUI
import AppKit
import ServiceManagement
import PRWatcherCore

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var newRepo = ""
    @State private var message = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Repositories (owner/name)") {
                List {
                    ForEach(store.repos, id: \.self) { r in
                        HStack {
                            Text(r)
                            Spacer()
                            Button("Remove") { store.removeRepo(r) }
                        }
                    }
                }
                .frame(height: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository URL or owner/name").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("", text: $newRepo, prompt: Text("https://github.com/owner/repo"))
                            .labelsHidden()
                            .onSubmit(add)
                        Button("Add", action: add)
                    }
                }
            }
            Section {
                Stepper("Check every \(store.intervalMinutes) min", value: $store.intervalMinutes, in: 1...60)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { message = error.localizedDescription }
                    }
                Button("Test GitHub token") {
                    Task {
                        do { message = "Signed in as \(try await GitHubClient().viewerLogin())" }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .frame(width: 546)
        .padding()
        .background(WindowFocuser())
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func add() {
        if store.addRepo(newRepo) { newRepo = ""; message = ""; Task { await store.refresh() } }
        else { message = "Invalid or duplicate repo" }
    }
}

/// Menu bar (accessory) apps can't take keyboard focus, so text fields in Settings stay
/// read-only. Switch to a regular app while the window is open and force it key.
private struct WindowFocuser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            v.window?.makeKeyAndOrderFront(nil)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
