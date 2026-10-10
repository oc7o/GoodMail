import GoodMailCore
import JMAPKit
import SwiftUI

struct ThreadListView: View {
    @Bindable var model: MailModel
    @Environment(\.compose) private var compose
    @State private var isNamingSearch = false
    @State private var searchName = ""
    @State private var unsubscribing: Email?

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
                        if let list = listMessage(in: thread) {
                            Divider()
                            Button("Unsubscribe…", systemImage: "list.bullet.rectangle") { unsubscribing = list }
                        }
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
        .navigationTitle(model.currentSavedSearch?.name ?? model.currentMailbox?.name ?? "Mail")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        .navigationSubtitle(subtitle)
        #endif
        .searchable(text: $model.searchText, prompt: model.currentSavedSearch == nil ? "Search" : "Refine")
        .searchSuggestions {
            if model.searchText.isEmpty {
                ForEach(Self.operatorHints, id: \.syntax) { hint in
                    Label {
                        HStack {
                            Text(hint.syntax).monospaced()
                            Text(hint.meaning).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                    .searchCompletion(hint.syntax)
                }
            }
        }
        .searchScopes($model.searchScope) {
            if model.currentSavedSearch == nil {
                Text(model.currentMailbox?.name ?? "Mailbox").tag(MailModel.SearchScope.mailbox)
                Text("All Mail").tag(MailModel.SearchScope.everywhere)
            }
        }
        .toolbar {
            ToolbarItem(placement: Self.composePlacement) {
                Button("New Message", systemImage: "square.and.pencil") { compose(.new()) }
                    .help("New Message (⌘N)")
            }
            ToolbarItem {
                Button("Save Search", systemImage: "bookmark") {
                    searchName = model.searchToSave?.name ?? ""
                    isNamingSearch = true
                }
                .disabled(model.searchToSave == nil)
                .help("Keep this search in the sidebar")
            }
            ToolbarItem {
                Toggle(isOn: $model.showsUnreadOnly) {
                    Label("Unread Only", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show only unread conversations")
            }
            #if os(macOS)
            ToolbarItem {
                // ⌘R is Reply now; Get New Mail is ⇧⌘N in the Mailbox menu (D30).
                Button("Get New Mail", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .help("Get New Mail (⇧⌘N)")
            }
            #endif
        }
        .safeAreaBar(edge: .bottom) {
            let counts = OutboxCounts(model.outbox)
            let isOffline = !model.isOnline || model.connectionProblem != nil
            // Online, a triage change waits only for the moment it takes to send it.
            OutboxPill(waiting: counts.waiting, failed: counts.failed,
                       pendingChanges: isOffline ? model.pendingChangeCount : 0, isOffline: isOffline) {
                model.showOutbox()
            }
            .padding(.bottom, 8)
            .help(model.connectionProblem ?? "Show the Outbox")
        }
        .sheet(item: $unsubscribing) { email in
            UnsubscribeSheet(email: email)
        }
        .alert("Save Search", isPresented: $isNamingSearch) {
            TextField("Name", text: $searchName)
            Button("Save") {
                let name = searchName.trimmingCharacters(in: .whitespaces)
                Task { await model.saveSearch(named: name.isEmpty ? model.searchToSave?.name ?? "Search" : name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved searches are kept on this device.")
        }
        .refreshable { await model.refresh() }
        .task(id: model.threadQuery) { await model.loadThreads() }
    }

    private static var operatorHints: [(syntax: String, meaning: String)] {
        let monthAgo = Date.now.addingTimeInterval(-30 * 86_400).formatted(.iso8601.year().month().day())
        return [
            ("from:", "Sender"), ("to:", "Recipient"), ("subject:", "Subject"), ("has:attachment", "With attachments"),
            ("is:unread", "Unread"), ("is:flagged", "Flagged"), ("in:", "Mailbox"),
            ("after:\(monthAgo)", "Received since"), ("before:\(monthAgo)", "Received before"),
        ]
    }

    private static var composePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .primaryAction
        #endif
    }

    /// The newest message of a mailing list in the conversation, if its stored copy tells (§5.7).
    private func listMessage(in thread: ThreadSummary) -> Email? {
        let junk = model.mailbox(.junk)?.id
        return thread.emails.last { email in
            email.offersUnsubscribe && !(junk.map { email.mailboxIds?[$0] == true } ?? false)
        }
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
            } else if let search = model.currentSavedSearch {
                ContentUnavailableView("No Matches", systemImage: "magnifyingglass", description: Text(search.query))
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
