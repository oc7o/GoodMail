import GoodMailCore
import JMAPKit
import SwiftUI

/// The reading pane: every message of one conversation.
struct ThreadView: View {
    let model: MailModel
    let threadID: String

    @State private var emails: [Email]?
    @State private var expanded: Set<String> = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let emails {
                VStack(alignment: .leading, spacing: 12) {
                    Text(emails.last?.subject?.nonEmpty ?? "(No Subject)")
                        .font(.title2.bold())
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                    ForEach(emails) { email in
                        MessageView(model: model, email: email, isExpanded: expanded.contains(email.id)) {
                            expanded.formSymmetricDifference([email.id])
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView(
                    "Couldn't Load Conversation", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if emails == nil {
                ProgressView()
            }
        }
        .toolbar { toolbar }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Runs again when a message joins the conversation while it is open.
        .task(id: model.thread(id: threadID)?.emails.count) { await load() }
    }

    /// Shows the stored copy at once if there is one, then whatever the server has.
    private func load() async {
        if let stored = await model.storedEmails(inThread: threadID) {
            show(stored)
        }
        do {
            show(try await model.fetchEmails(inThread: threadID))
            error = nil
        } catch {
            if emails == nil, !Task.isCancelled { self.error = error.localizedDescription }
        }
        await model.setRead(true, threadID: threadID, userInitiated: false)
    }

    private func show(_ emails: [Email]) {
        let known = Set(self.emails?.map(\.id) ?? [])
        let unread = emails.filter { !$0.has(.seen) && !known.contains($0.id) }.map(\.id)
        expanded.formUnion(unread)
        if self.emails == nil, let last = emails.last { expanded.insert(last.id) }
        if self.emails != emails { self.emails = emails }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let summary = model.thread(id: threadID)
        ToolbarItemGroup {
            if model.canArchive {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.archive(threadID: threadID) }
                }
                .keyboardShortcut("a", modifiers: [.control, .command])
            }
            if model.canTrash {
                Button("Trash", systemImage: "trash") {
                    Task { await model.trash(threadID: threadID) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            Menu("Move", systemImage: "folder") {
                ForEach(model.mailboxRows.filter { $0.id != model.currentMailbox?.id }) { row in
                    Button(row.mailbox.name, systemImage: row.mailbox.role.symbolName) {
                        Task { await model.move(threadID: threadID, to: row.id) }
                    }
                }
            }
        }
        ToolbarItemGroup {
            Button("Mark as Unread", systemImage: "envelope.badge") {
                Task { await model.setRead(false, threadID: threadID) }
            }
            .keyboardShortcut("u", modifiers: [.shift, .command])
            Button(
                summary?.isFlagged == true ? "Unflag" : "Flag",
                systemImage: summary?.isFlagged == true ? "flag.fill" : "flag"
            ) {
                Task { await model.toggleFlag(threadID: threadID) }
            }
            .keyboardShortcut("l", modifiers: [.shift, .command])
        }
    }
}
