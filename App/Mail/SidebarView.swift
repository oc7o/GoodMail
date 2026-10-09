import GoodMailCore
import JMAPKit
import MailStore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: MailModel
    @Environment(AppModel.self) private var appModel
    @State private var renaming: SavedSearch?
    @State private var newName = ""

    var body: some View {
        List(selection: $model.destination) {
            Section("Mailboxes") {
                ForEach(model.mailboxRows) { row in
                    Label(row.mailbox.name, systemImage: row.mailbox.role.symbolName)
                        .badge(badge(for: row.mailbox))
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .tag(MailModel.Destination.mailbox(row.id))
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
        .safeAreaInset(edge: .bottom) {
            Menu {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", action: appModel.signOut)
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
    }

    private func badge(for mailbox: Mailbox) -> Int {
        switch mailbox.role {
        case .drafts?: mailbox.totalEmails
        case .junk?, .trash?: 0
        default: mailbox.unreadThreads
        }
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
