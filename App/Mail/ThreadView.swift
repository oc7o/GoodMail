import GoodMailCore
import JMAPKit
import SwiftUI

/// The reading pane: every message of one conversation.
struct ThreadView: View {
    let model: MailModel
    let threadID: String

    @Environment(\.compose) private var compose
    @State private var emails: [Email]?
    @State private var expanded: Set<String> = []
    @State private var error: String?
    @State private var unsubscribing: Email?

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
        .focusedSceneValue(\.replyTarget, replyTarget.map { ReplyTarget(emailID: $0.id, compose: compose) })
        .sheet(item: $unsubscribing) { email in
            UnsubscribeSheet(email: email)
        }
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

    /// The message Reply, Reply All and Forward act on: the newest that isn't a draft.
    private var replyTarget: Email? {
        emails?.last { !$0.has(.draft) }
    }

    /// The newest message of a mailing list, unless it is in Junk (§2.6).
    private var listMessage: Email? {
        let junk = model.mailbox(.junk)?.id
        return emails?.last { email in
            email.offersUnsubscribe && !(junk.map { email.mailboxIds?[$0] == true } ?? false)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let summary = model.thread(id: threadID)
        let target = replyTarget?.id
        #if os(iOS)
        // An iPhone's bar has no room for three more buttons: one menu at the bottom, as in Mail.
        ToolbarItem(placement: .bottomBar) {
            Menu {
                if let target { MessageActions(emailID: target) }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .disabled(target == nil)
        }
        #else
        ToolbarItemGroup {
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                if let target { compose(.reply(emailID: target, all: false)) }
            }
            .disabled(target == nil)
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                if let target { compose(.reply(emailID: target, all: true)) }
            }
            .disabled(target == nil)
            Button("Forward", systemImage: "arrowshape.turn.up.right") {
                if let target { compose(.forward(emailID: target, asAttachment: false)) }
            }
            .disabled(target == nil)
        }
        #endif
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
                ForEach(model.mailboxRows.filter { $0.id != model.listedMailboxID }) { row in
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
            Menu("More", systemImage: "ellipsis.circle") {
                if let target {
                    Button("Forward as Attachment", systemImage: "paperclip") {
                        compose(.forward(emailID: target, asAttachment: true))
                    }
                }
                if let listMessage {
                    Button("Unsubscribe…", systemImage: "list.bullet.rectangle") { unsubscribing = listMessage }
                }
            }
            .disabled(target == nil && listMessage == nil)
        }
    }
}
