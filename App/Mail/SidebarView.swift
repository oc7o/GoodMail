import GoodMailCore
import JMAPKit
import MailStore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: MailModel
    @Environment(AppModel.self) private var appModel
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
                    Task { await appModel.beginSignOut() }
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
            presenting: appModel.pendingSignOut
        ) { _ in
            Button("Sign Out and Delete", role: .destructive) { appModel.signOut() }
            Button("Show Outbox") {
                appModel.pendingSignOut = nil
                model.destination = .outbox
            }
            Button("Cancel", role: .cancel) { appModel.pendingSignOut = nil }
        } message: { summary in
            Text(SignOutConfirmation.message(for: summary))
        }
    }

    /// Only while something is in it, or drafts wait to reach Fastmail; and while it is open.
    private var showsOutbox: Bool {
        !model.outbox.items.isEmpty || !model.outbox.unsyncedDrafts.isEmpty || model.destination == .outbox
    }

    private var isConfirmingSignOut: Binding<Bool> {
        Binding(get: { appModel.pendingSignOut != nil }, set: { if !$0 { appModel.pendingSignOut = nil } })
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

    /// "2 messages haven't been sent and 1 draft exists only on this device. Signing out deletes them."
    static func message(for summary: UnsentSummary) -> String {
        let messages = summary.waiting + summary.sending + summary.failed
        let drafts = summary.localOnlyDrafts
        var parts: [String] = []
        if messages > 0 {
            parts.append(messages == 1 ? "1 message hasn't been sent" : "\(messages) messages haven't been sent")
        }
        if drafts > 0 {
            parts.append(drafts == 1 ? "1 draft exists only on this device" : "\(drafts) drafts exist only on this device")
        }
        return parts.joined(separator: " and ") + ". Signing out deletes " + (messages + drafts == 1 ? "it." : "them.")
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
