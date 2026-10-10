import GoodMailCore
import JMAPKit
import SwiftUI

struct MaskedEmailListView: View {
    @Bindable var model: MailModel
    @Environment(MainWindowState.self) private var window

    enum StateFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case disabled = "Disabled"
        case deleted = "Deleted"
        case all = "All"

        var id: Self { self }

        func includes(_ state: MaskedEmail.State) -> Bool {
            switch self {
            case .active: state == .enabled || state == .pending
            case .disabled: state == .disabled
            case .deleted: state == .deleted
            case .all: true
            }
        }
    }

    @State private var search = ""
    @State private var filter = StateFilter.active

    var body: some View {
        List(selection: $model.selectedMaskedEmailID) {
            ForEach(visible) { masked in
                MaskedEmailRow(masked: masked)
                    .tag(masked.id)
                    .contextMenu {
                        Button("Copy Address", systemImage: "doc.on.doc") { Pasteboard.copy(masked.email) }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visible.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "No \(filter == .all ? "" : filter.rawValue + " ")Masked Emails", systemImage: "theatermasks",
                        description: Text("Masked addresses forward to your inbox and can be switched off at any time."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("Masked Email")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        #endif
        .searchable(text: $search, prompt: "Search addresses")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .primaryAction) {
                // ⌘N is New Message now; New Masked Email is ⌃⌘N in the File menu (D30).
                Button("New Masked Email", systemImage: "plus") { window.newMaskedEmail(in: model) }
                    .help("New Masked Email (⌃⌘N)")
            }
        }
        .refreshable { await model.loadMaskedEmails() }
        .task { await model.loadMaskedEmails() }
    }

    private var visible: [MaskedEmail] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.maskedEmails
            .filter { masked in
                guard filter.includes(masked.state) else { return false }
                guard !query.isEmpty else { return true }
                return [masked.email, masked.description, masked.forDomain]
                    .contains { $0?.localizedCaseInsensitiveContains(query) == true }
            }
            .sorted { ($0.lastMessageAt ?? $0.createdAt ?? .distantPast) > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast) }
    }
}

struct MaskedEmailRow: View {
    let masked: MaskedEmail

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(masked.label)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if masked.state != .enabled {
                    Text(masked.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: .capsule)
                }
            }
            Text(masked.email)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let last = masked.lastMessageAt {
                Text("Last mail \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

extension MaskedEmail {
    /// What the address is for: its description, else the site it was created on.
    var label: String {
        description?.nonEmpty ?? forDomain.flatMap { URL(string: $0)?.host() ?? $0.nonEmpty } ?? email
    }
}

extension MaskedEmail.State {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .enabled: "Active"
        case .disabled: "Disabled"
        case .deleted: "Deleted"
        default: rawValue.capitalized
        }
    }
}
