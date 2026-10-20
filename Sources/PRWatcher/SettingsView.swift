import SwiftUI
import AppKit
import ServiceManagement
import PRWatcherCore

struct SettingsView: View {
    @ObservedObject var store: Store
    let onClose: () -> Void
    @State private var newRepo = ""
    @State private var message = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onClose) { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 60, height: 1)   // balances the Back button so the title stays centred
            }
            .padding(12)
            Divider()
            form
        }
    }

    private var form: some View {
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
        .padding(.horizontal, 12)
    }

    private func add() {
        if store.addRepo(newRepo) { newRepo = ""; message = ""; Task { await store.refresh() } }
        else { message = "Invalid or duplicate repo" }
    }
}
