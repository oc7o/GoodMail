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
        .task { await load() }
    }

    private func load() async {
        do {
            let emails = try await model.client.emails(inThread: threadID)
            expanded = Set(emails.filter { !$0.has(.seen) }.map(\.id) + [emails.last?.id].compactMap { $0 })
            self.emails = emails
            await model.setRead(true, threadID: threadID)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
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
