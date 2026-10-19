import SwiftUI
import PRWatcherCore

enum Col {
    static let repo: CGFloat = 130
    static let status: CGFloat = 125
    static let copilot: CGFloat = 60
}

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showAllOpen") private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $showAll) {
                Text("Unread (\(unreadPRs.count))").tag(false)
                Text("All open (\(store.pullRequests.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            HStack(alignment: .bottom, spacing: 12) {
                if showAll { Text("Repo").frame(width: Col.repo, alignment: .leading) }
                HStack(spacing: 8) {
                    Text("PR").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status").frame(width: Col.status, alignment: .leading)
                    Text("Review").frame(width: Col.copilot, alignment: .leading)
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
                    if showAll {
                        ForEach(grouped, id: \.repo) { group in
                            HStack(alignment: .top, spacing: 12) {
                                Text(group.repo)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: Col.repo, alignment: .topLeading)
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(group.prs) { pr in PRRow(pr: pr, store: store, showRepo: false) }
                                }
                            }
                            Divider()
                        }
                    } else {
                        ForEach(visible) { pr in PRRow(pr: pr, store: store) }
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
                Button("Mark all read") { store.markAllRead() }.disabled(store.unreadCount == 0)
                Button("Settings") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
            .padding(8)
        }
        .frame(width: 882)
    }

    private var unreadPRs: [PullRequest] {
        store.pullRequests.filter { !store.state.unread(for: $0.key).isEmpty }
    }

    private var visible: [PullRequest] { showAll ? sorted : sorted.filter { !store.state.unread(for: $0.key).isEmpty } }

    private var grouped: [(repo: String, prs: [PullRequest])] {
        Dictionary(grouping: sorted, by: \.repo).map { ($0.key, $0.value) }.sorted { $0.repo < $1.repo }
    }

    private var emptyText: String {
        if !store.status.isEmpty && store.pullRequests.isEmpty { return store.status }
        return showAll ? "No open PRs of yours in the watched repos" : "Nothing new — all caught up"
    }

    private var sorted: [PullRequest] {
        store.pullRequests.sorted {
            let a = store.state.unread(for: $0.key).count, b = store.state.unread(for: $1.key).count
            return a != b ? a > b : $0.key < $1.key
        }
    }
}

struct PRRow: View {
    let pr: PullRequest
    @ObservedObject var store: Store
    var showRepo = true

    var body: some View {
        let unread = store.state.unread(for: pr.key)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                store.markRead(pr)
                NSWorkspace.shared.open(pr.url)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((showRepo ? "\(pr.repo) #\(pr.number)" : "#\(pr.number)")
                            + (unread.isEmpty ? "" : " · \(unread.count) new"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(pr.title).font(.body.weight(unread.isEmpty ? .regular : .semibold)).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 8) {
                        StatusBadge(status: pr.status)
                        OthersCell(review: pr.review)
                    }
                    .frame(width: Col.status, alignment: .leading)
                    CopilotCell(review: pr.review)
                        .frame(width: Col.copilot, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
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
