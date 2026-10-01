import GoodMailCore
import JMAPKit
import SwiftUI

struct ThreadListView: View {
    @Bindable var model: MailModel

    var body: some View {
        List(selection: $model.selectedThreadID) {
            ForEach(model.threads) { thread in
                ThreadRow(thread: thread, showsRecipients: showsRecipients)
                    .tag(thread.id)
                    .swipeActions(edge: .leading) { readButton(for: thread).tint(.blue) }
                    .swipeActions(edge: .trailing) {
                        if model.canTrash { trashButton(for: thread) }
                        if model.canArchive { archiveButton(for: thread).tint(.purple) }
                        flagButton(for: thread).tint(.orange)
                    }
                    .contextMenu {
                        readButton(for: thread)
                        flagButton(for: thread)
                        Divider()
                        if model.canArchive { archiveButton(for: thread) }
                        if model.canTrash { trashButton(for: thread) }
                    }
                    .onAppear {
                        if thread.id == model.threads.last?.id {
                            Task { await model.loadMoreThreads() }
                        }
                    }
            }
            if model.hasMoreThreads {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle(model.currentMailbox?.name ?? "Mail")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        .navigationSubtitle(subtitle)
        #endif
        .searchable(text: $model.searchText, prompt: "Search")
        .searchScopes($model.searchScope) {
            Text(model.currentMailbox?.name ?? "Mailbox").tag(MailModel.SearchScope.mailbox)
            Text("All Mail").tag(MailModel.SearchScope.everywhere)
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $model.showsUnreadOnly) {
                    Label("Unread Only", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show only unread conversations")
            }
            #if os(macOS)
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            if let problem = model.connectionProblem {
                Label("Offline. Showing saved mail.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
                    .help(problem)
            }
        }
        .refreshable { await model.refresh() }
        .task(id: model.threadQuery) { await model.loadThreads() }
    }

    private var showsRecipients: Bool {
        let role = model.currentMailbox?.role
        return role == .sent || role == .drafts
    }

    private var subtitle: String {
        guard let total = model.totalThreads else { return "" }
        return "\(total) conversation\(total == 1 ? "" : "s")"
    }

    @ViewBuilder private var emptyState: some View {
        if model.threads.isEmpty {
            if model.isLoadingThreads {
                ProgressView()
            } else if !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.showsUnreadOnly {
                ContentUnavailableView("No Unread Mail", systemImage: "checkmark.circle")
            } else {
                ContentUnavailableView("No Mail", systemImage: "tray")
            }
        }
    }

    private func readButton(for thread: ThreadSummary) -> some View {
        Button(
            thread.isUnread ? "Mark as Read" : "Mark as Unread",
            systemImage: thread.isUnread ? "envelope.open" : "envelope.badge"
        ) {
            Task { await model.setRead(thread.isUnread, threadID: thread.id) }
        }
    }

    private func flagButton(for thread: ThreadSummary) -> some View {
        Button(thread.isFlagged ? "Unflag" : "Flag", systemImage: thread.isFlagged ? "flag.slash" : "flag") {
            Task { await model.toggleFlag(threadID: thread.id) }
        }
    }

    private func archiveButton(for thread: ThreadSummary) -> some View {
        Button("Archive", systemImage: "archivebox") {
            Task { await model.archive(threadID: thread.id) }
        }
    }

    private func trashButton(for thread: ThreadSummary) -> some View {
        Button("Trash", systemImage: "trash", role: .destructive) {
            Task { await model.trash(threadID: thread.id) }
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary
    let showsRecipients: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(participants)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if thread.emails.count > 1 {
                        Text(thread.emails.count, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: .capsule)
                    }
                    Spacer(minLength: 8)
                    if let date = thread.anchor?.receivedAt {
                        Text(date.listTimestamp)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(thread.anchor?.subject?.nonEmpty ?? "(No Subject)")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if thread.hasAttachment {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                    }
                    if thread.isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .imageScale(.small)
                Text(thread.anchor?.preview ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var participants: String {
        let addresses = thread.emails.flatMap { (showsRecipients ? $0.to : $0.from) ?? [] }
        var seen = Set<String>()
        let names = addresses.filter { seen.insert($0.email.lowercased()).inserted }.map(\.displayName)
        let joined = names.isEmpty ? "(No Sender)" : names.joined(separator: ", ")
        return showsRecipients ? "To: \(joined)" : joined
    }
}
