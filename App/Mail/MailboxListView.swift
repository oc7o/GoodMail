import JMAPKit
import SwiftUI

/// Temporary M0 screen proving the JMAP connection; replaced by the full split view in M1.
struct MailboxListView: View {
    let client: JMAPClient

    @Environment(AppModel.self) private var model
    @State private var rows: [Row] = []
    @State private var error: String?

    struct Row: Identifiable {
        let mailbox: Mailbox
        let depth: Int
        var id: String { mailbox.id }
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                HStack {
                    Label(row.mailbox.name, systemImage: Self.icon(for: row.mailbox.role))
                    Spacer()
                    if row.mailbox.unreadEmails > 0 {
                        Text(row.mailbox.unreadEmails, format: .number)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 16)
            }
            .overlay {
                if let error {
                    ContentUnavailableView("Couldn't load mailboxes", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                }
            }
            .navigationTitle("Mailboxes")
            .toolbar {
                ToolbarItem {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", action: model.signOut)
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            let accountId = try await client.accountId(for: Capability.mail)
            let mailboxes = try await client.call(MailboxGet(accountId: accountId)).list
            rows = Self.flatten(mailboxes)
            error = nil
        } catch JMAPError.unauthorized {
            model.signOut()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Depth-first order: role mailboxes first, then by `sortOrder` and name.
    static func flatten(_ mailboxes: [Mailbox]) -> [Row] {
        let children = Dictionary(grouping: mailboxes, by: \.parentId)
        func sorted(_ list: [Mailbox]) -> [Mailbox] {
            list.sorted { ($0.role == nil ? 1 : 0, $0.sortOrder, $0.name) < ($1.role == nil ? 1 : 0, $1.sortOrder, $1.name) }
        }
        func walk(_ parentId: String?, depth: Int) -> [Row] {
            sorted(children[parentId] ?? []).flatMap { mailbox in
                [Row(mailbox: mailbox, depth: depth)] + walk(mailbox.id, depth: depth + 1)
            }
        }
        return walk(nil, depth: 0)
    }

    static func icon(for role: Mailbox.Role?) -> String {
        switch role {
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
