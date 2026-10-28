import SwiftUI
import PRWatcherCore

extension VerticalAlignment {
    private enum TitleLine: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// Centre of the first line of a PR title; the status/review cells align to it.
    static let titleLine = VerticalAlignment(TitleLine.self)
}

enum Col {
    static let repo: CGFloat = 130
    static let status: CGFloat = 125
    static let copilot: CGFloat = 60
}

struct ContentView: View {
    @ObservedObject var store: Store
    @AppStorage("selectedTab") private var tab = Tab.all
    /// PRs that had unread activity when the panel was opened. They keep their red dot while it stays
    /// open; the activity itself is marked read right away so the menu bar count clears.
    @State private var highlighted: Set<String> = []
    @State private var showSettings = false

    @State private var newPR = ""
    @State private var addMessage = ""

    enum Tab: String { case all, assigned, custom }

    var body: some View {
        Group {
            if showSettings {
                SettingsView(store: store) { showSettings = false }
            } else {
                list
            }
        }
        .frame(width: 882)
        .onAppear(perform: panelOpened)
        .onDisappear { highlighted = []; showSettings = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in panelOpened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in highlighted = [] }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("Opened by me (\(store.pullRequests.count))").tag(Tab.all)
                Text("Assigned to me (\(store.assigned.count))").tag(Tab.assigned)
                Text("Other (\(store.customRefs.count))").tag(Tab.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            if tab == .custom { addBar }
            HStack(alignment: .bottom, spacing: 12) {
                Text("Repo").frame(width: Col.repo, alignment: .leading)
                HStack(spacing: 8) {
                    Text("PR").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status").frame(width: Col.status, alignment: .leading)
                    Text("Review").frame(width: Col.copilot, alignment: .leading)
                    // Spans the row's trash column: 50 pt button + 6 pt gap, minus this stack's 8 pt spacing.
                    if tab == .custom { Text("Actions").frame(width: 48, alignment: .center) }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if visible.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                    if tab == .custom {
                        ForEach(store.customRefs.filter { ref in !store.custom.contains { $0.key == ref.key } }) { ref in
                            HStack {
                                Text(ref.key).font(.caption).foregroundStyle(.secondary)
                                if store.checkedCustom.contains(ref.key) {
                                    Text("not found or no access").font(.caption).foregroundStyle(.red)
                                } else {
                                    Text("loading…").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { store.removeCustomPR(ref) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Remove")
                            }
                        }
                    }
                    ForEach(grouped, id: \.repo) { group in
                        HStack(alignment: .top, spacing: 12) {
                            Text(group.repo)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: Col.repo, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(group.prs) { pr in
                                    PRRow(pr: pr, store: store, isUnread: isUnread(pr),
                                          onRemove: tab == .custom ? { remove(pr.key) } : nil)
                                }
                            }
                        }
                        Divider()
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 300, idealHeight: 570, maxHeight: 630)
            Divider()
            HStack {
                if store.isRefreshing { ProgressView().controlSize(.small) }
                else if !store.status.isEmpty { Text(store.status).foregroundStyle(.red).lineLimit(1) }
                else if let t = store.lastChecked { Text("Checked \(t, style: .relative) ago").foregroundStyle(.secondary) }
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                Button("Settings") { showSettings = true }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
            .padding(8)
        }
    }

    private func panelOpened() {
        highlighted.formUnion(store.state.unread.map(\.prKey))
        store.markAllRead()   // also acknowledges open Copilot threads for the menu bar count
    }

    private func isUnread(_ pr: PullRequest) -> Bool {
        highlighted.contains(pr.key) || !store.state.unread(for: pr.key).isEmpty
    }

    private var visible: [PullRequest] {
        switch tab {
        case .all: return store.pullRequests.sorted { $0.key < $1.key }
        case .assigned: return store.assigned.sorted { $0.key < $1.key }
        case .custom: return store.custom.sorted { $0.key < $1.key }
        }
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("", text: $newPR, prompt: Text("PR URL, e.g. https://github.com/owner/repo/pull/123"))
                    .labelsHidden()
                    .onSubmit(addPR)
                Button(action: addPR) { Image(systemName: "plus") }
                    .help("Add pull request")
            }
            if !addMessage.isEmpty { Text(addMessage).font(.caption).foregroundStyle(.red) }
        }
        .padding([.horizontal, .top], 12)
    }

    private func addPR() {
        if store.addCustomPR(newPR) {
            newPR = ""
            addMessage = ""
            Task { await store.refresh() }
        } else {
            addMessage = "Enter a valid PR link that isn't already added"
        }
    }

    private func remove(_ key: String) {
        if let ref = store.customRefs.first(where: { $0.key == key }) { store.removeCustomPR(ref) }
    }

    private var grouped: [(repo: String, prs: [PullRequest])] {
        Dictionary(grouping: visible, by: \.repo).map { ($0.key, $0.value) }.sorted { $0.repo < $1.repo }
    }

    private var emptyText: String {
        if !store.status.isEmpty && store.pullRequests.isEmpty { return store.status }
        switch tab {
        case .all: return "No open PRs of yours in the watched repos"
        case .assigned: return "No open PRs assigned to you in the watched repos"
        case .custom: return store.customRefs.isEmpty ? "No other PRs yet — paste a PR link above and press +" : ""
        }
    }
}

struct PRRow: View {
    let pr: PullRequest
    @ObservedObject var store: Store
    let isUnread: Bool
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .titleLine, spacing: 6) {
            main
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .frame(width: 50)
                    .help("Remove from the Other list")
                    .alignmentGuide(.titleLine) { d in d[VerticalAlignment.center] }
            }
        }
    }

    private var main: some View {
        Button {
            store.markRead(pr)
            NSWorkspace.shared.open(pr.url)
        } label: {
            HStack(alignment: .titleLine, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if isUnread { Circle().fill(.red).frame(width: 7, height: 7) }
                        Text(verbatim: "#" + String(pr.number)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(pr.title).font(.body.weight(isUnread ? .semibold : .regular)).lineLimit(2)
                        .alignmentGuide(.titleLine) { d in d[.firstTextBaseline] - 5 }
                }
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    StatusBadge(status: pr.status)
                    OthersCell(review: pr.review)
                }
                .frame(width: Col.status, alignment: .leading)
                // An empty cell (no Copilot review) would collapse and shift Status; keep the column width fixed.
                Color.clear
                    .frame(width: Col.copilot, height: 1)
                    .overlay(alignment: .leading) { CopilotCell(review: pr.review) }
            }
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    let status: PRStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .open: return .blue
        case .approved: return .green
        case .changesRequested: return .orange
        case .draft: return .gray
        case .merged: return .purple
        case .closed: return .red
        }
    }
}

struct CopilotCell: View {
    let review: ReviewSummary
    @State private var hovering = false

    var body: some View {
        if review.copilotReviewed {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").foregroundStyle(color)
                Text("\(review.copilotUnresolved)")
            }
            .font(.caption)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .bottom) {
                ScrollView {
                    Text(review.copilotBody ?? review.copilotHeadline ?? "No review text")
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(width: 380, height: 220)
            }
        }
    }

    private var color: Color {
        switch review.copilotVerdict {
        case .green: return .green
        case .yellow: return .yellow
        case .blue: return .blue
        case nil: return .gray
        }
    }
}

struct OthersCell: View {
    let review: ReviewSummary

    var body: some View {
        if review.otherUnresolved > 0 {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left")
                Text("\(review.otherUnresolved)")
            }
            .font(.caption)
            .help("\(review.otherUnresolved) unresolved comment thread(s) from other reviewers")
        }
    }
}
