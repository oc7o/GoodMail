import GoodMailCore
import JMAPKit
import MailStore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: MailModel
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowState.self) private var window
    @State private var renaming: SavedSearch?
    @State private var newName = ""
    @State private var isReplacingToken = false

    var body: some View {
        List(selection: $model.destination) {
            Section("Mailboxes") {
                ForEach(model.mailboxRows) { row in
                    Label(row.mailbox.name, systemImage: row.mailbox.role.symbolName)
                        .badge(badge(for: row.mailbox))
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .tag(MailModel.Destination.mailbox(row.id))
                }
                if showsOutbox {
                    OutboxSidebarLabel(outbox: model.outbox)
                        .tag(MailModel.Destination.outbox)
                }
            }
            if !model.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.savedSearches) { search in
                        Label(search.name, systemImage: "magnifyingglass")
                            .help(search.query)
                            .tag(MailModel.Destination.savedSearch(search.id))
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") {
                                    newName = search.name
                                    renaming = search
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await model.deleteSavedSearch(id: search.id) }
                                }
                            }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { model.savedSearches[$0].id }
                        Task { for id in ids { await model.deleteSavedSearch(id: id) } }
                    }
                }
            }
            Section("Privacy") {
                Label("Masked Email", systemImage: "theatermasks")
                    .tag(MailModel.Destination.maskedEmail)
            }
        }
        .navigationTitle("GoodMail")
        .alert(
            "Rename Saved Search",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { search in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await model.renameSavedSearch(id: search.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        #endif
        .safeAreaBar(edge: .bottom) {
            Menu {
                Button("Replace Token…", systemImage: "key") { isReplacingToken = true }
                Divider()
                Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { window.pendingSignOut = await appModel.beginSignOut() }
                }
            } label: {
                Label(model.username ?? "Account", systemImage: "person.crop.circle")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $isReplacingToken) { ReplaceTokenView() }
        .confirmationDialog(
            SignOutConfirmation.title, isPresented: isConfirmingSignOut, titleVisibility: .visible,
            presenting: window.pendingSignOut
        ) { summary in
            Button(SignOutConfirmation.signOutTitle(for: summary), role: .destructive) { appModel.signOut() }
            Button("Show Outbox") {
                window.pendingSignOut = nil
                model.showOutbox()
            }
            Button("Cancel", role: .cancel) { window.pendingSignOut = nil }
        } message: { summary in
            Text(SignOutConfirmation.message(for: summary))
        }
    }

    /// Only while something is in it, or drafts wait to reach Fastmail; and while it is open.
    private var showsOutbox: Bool {
        !model.outbox.items.isEmpty || !model.outbox.unsyncedDrafts.isEmpty || model.destination == .outbox
    }

    private var isConfirmingSignOut: Binding<Bool> {
        Binding(get: { window.pendingSignOut != nil }, set: { if !$0 { window.pendingSignOut = nil } })
    }

    private func badge(for mailbox: Mailbox) -> Int {
        switch mailbox.role {
        case .drafts?: mailbox.totalEmails
        case .junk?, .trash?: 0
        default: mailbox.unreadThreads
        }
    }
}

/// The Outbox in the sidebar: its badge counts what hasn't gone out, prominent (red) when something failed.
struct OutboxSidebarLabel: View {
    let outbox: Outbox

    var body: some View {
        let failed = outbox.items.filter { if case .failed = $0.state { true } else { false } }.count
        Label("Outbox", systemImage: failed > 0 ? "exclamationmark.triangle" : "tray.and.arrow.up")
            .badge(outbox.items.count)
            .badgeProminence(failed > 0 ? .increased : .standard)
            .accessibilityValue(failed > 0 ? "\(failed) failed" : "")
    }
}

/// What Sign Out asks when it would delete something nobody else has (D36).
enum SignOutConfirmation {
    static let title = "Sign Out of GoodMail?"

    /// "2 messages haven't been sent and 1 draft exists only on this device. Signing out deletes them." A message
    /// on its way, held for Undo or with its outcome unknown, is no longer GoodMail's to delete: Fastmail may
    /// send it whatever happens here, unless it is cancelled in the Outbox first.
    static func message(for summary: UnsentSummary) -> String {
        var sentences: [String] = []
        let deleted = summary.waiting + summary.failed + summary.localOnlyDrafts
        if let lost = UnsentMailText.lost(messages: summary.waiting + summary.failed, drafts: summary.localOnlyDrafts) {
            sentences.append(lost + ". Signing out deletes " + (deleted == 1 ? "it." : "them."))
        }
        if summary.sending > 0 {
            sentences.append(summary.sending == 1
                ? "1 message is being sent and may still go out after you sign out."
                : "\(summary.sending) messages are being sent and may still go out after you sign out.")
        }
        return sentences.joined(separator: " ")
    }

    /// The destructive button says Delete only when signing out deletes something.
    static func signOutTitle(for summary: UnsentSummary) -> String {
        summary.waiting + summary.failed + summary.localOnlyDrafts > 0 ? "Sign Out and Delete" : "Sign Out"
    }
}

/// How mail that exists only on this device is named when signing out or in would delete it (D36).
enum UnsentMailText {
    /// "2 messages haven't been sent and 1 draft exists only on this device"; `nil` for none of either.
    static func lost(messages: Int, drafts: Int) -> String? {
        var parts: [String] = []
        if messages > 0 {
            parts.append(messages == 1 ? "1 message hasn't been sent" : "\(messages) messages haven't been sent")
        }
        if drafts > 0 {
            parts.append(drafts == 1 ? "1 draft exists only on this device" : "\(drafts) drafts exist only on this device")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Signing in with another account: what the account used before left here. `nil` when that couldn't be read.
    static func otherAccount(_ summary: UnsentSummary?) -> String {
        let messages = (summary?.waiting ?? 0) + (summary?.sending ?? 0) + (summary?.failed ?? 0)
        guard let summary, let lost = lost(messages: messages, drafts: summary.localOnlyDrafts) else {
            return "The account you used before still has mail on this device, and GoodMail couldn't check it for "
                + "messages that weren't sent. Signing in with another account deletes it."
        }
        return "From the account you used before, " + lost + ". Signing in with another account deletes "
            + (messages + summary.localOnlyDrafts == 1 ? "it." : "them.")
    }
}

extension Mailbox.Role? {
    var symbolName: String {
        switch self {
        case .inbox?: "tray"
        case .archive?: "archivebox"
        case .drafts?: "doc"
        case .sent?: "paperplane"
        case .junk?: "xmark.bin"
        case .trash?: "trash"
        default: "folder"
        }
    }
}
