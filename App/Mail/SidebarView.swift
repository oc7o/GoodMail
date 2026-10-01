import GoodMailCore
import JMAPKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: MailModel
    @Environment(AppModel.self) private var appModel

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
            Section("Privacy") {
                Label("Masked Email", systemImage: "theatermasks")
                    .tag(MailModel.Destination.maskedEmail)
            }
        }
        .navigationTitle("GoodMail")
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
