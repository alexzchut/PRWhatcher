import SwiftUI
import PRWatcherCore

@main
struct PRWatcherApp: App {
    @StateObject private var store: Store

    init() {
        let notifier = Notifier()
        notifier.start()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRWatcher")
        let s = Store(fetcher: GitHubClient(), notifier: notifier,
                      stateURL: dir.appendingPathComponent("state.json"))
        s.startPolling()
        _store = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.pull")
                if store.unreadCount > 0 { Text("\(store.unreadCount)") }
            }
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(store: store) }
    }
}
