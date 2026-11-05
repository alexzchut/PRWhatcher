import SwiftUI
import AppKit
import ServiceManagement
import PRWatcherCore

struct SettingsView: View {
    @ObservedObject var store: Store
    let onClose: () -> Void
    @AppStorage("settingsTab") private var tab = Tab.repositories
    @State private var newRepo = ""
    @State private var message = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum Tab: String { case repositories, pullRequests, general }

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
            Picker("", selection: $tab) {
                Text("Repositories (\(store.repos.count))").tag(Tab.repositories)
                Text("Pull requests").tag(Tab.pullRequests)
                Text("General").tag(Tab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            form
                // Fixed so the panel doesn't resize between tabs; a long repo list scrolls with the form.
                .frame(height: 400)
        }
        .onChange(of: tab) { message = "" }
    }

    private var form: some View {
        Form {
            switch tab {
            case .repositories: repositories
            case .pullRequests: pullRequests
            case .general: general
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }

    // Plain rows, not a List: a List nested in a Form doesn't scroll, so a fixed height would clip it.
    @ViewBuilder private var repositories: some View {
        Section("Repositories (owner/name)") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Repository URL or owner/name").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $newRepo, prompt: Text("https://github.com/owner/repo"))
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add)
                }
            }
            ForEach(store.repos, id: \.self) { r in
                HStack {
                    Text(r)
                    Spacer()
                    Button("Remove") { store.removeRepo(r) }
                }
            }
        }
    }

    @ViewBuilder private var pullRequests: some View {
        Section {
            HStack(spacing: 16) {
                Toggle("Open", isOn: .constant(true)).disabled(true)
                Toggle("Draft", isOn: $store.statuses.draft)
                Toggle("Merged", isOn: $store.statuses.merged)
                Toggle("Closed", isOn: $store.statuses.closed)
            }
            .toggleStyle(.checkbox)
        } header: {
            Text("PR statuses to include")
        } footer: {
            Text("Applies to Opened by me and Assigned to me. Merged and closed PRs are limited to the 20 most recently updated per search.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Include team review requests", isOn: $store.statuses.teamReviews)
        } header: {
            Text("Assigned to me")
        } footer: {
            Text("Also lists PRs waiting for a review from one of your teams, up to the 50 most recently updated. A PR leaves the list once GitHub no longer shows that request as pending.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var general: some View {
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
    }

    private func add() {
        if store.addRepo(newRepo) { newRepo = ""; message = ""; Task { await store.refresh() } }
        else { message = "Invalid or duplicate repo" }
    }
}
