import GoodMailCore
import JMAPKit
import SwiftUI

/// The composer's From: the identities Fastmail shows in compose, then the masked addresses in a searchable list,
/// with those Fastmail won't send from marked (no sending identity, D21), then the login name when no identity is
/// known (§5.2). The composer takes care of what follows a change: signature, Reply-To, Bcc and Message-ID.
struct SenderPicker: View {
    @Binding var from: EmailAddress?
    let options: [SenderOption]

    @State private var isChoosingMask = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("From:")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(identities) { option in
                    Button {
                        from = option.address
                    } label: {
                        Text(Self.title(of: option.address))
                        if isCurrent(option) { Image(systemName: "checkmark") }
                    }
                }
                if !masks.isEmpty {
                    Divider()
                    Button("Masked Addresses…", systemImage: "theatermasks") { isChoosingMask = true }
                }
            } label: {
                currentLabel
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("From")
            .accessibilityValue(from?.email ?? "No address")
            Spacer(minLength: 0)
        }
        .popover(isPresented: $isChoosingMask, arrowEdge: .bottom) {
            MaskedSenderList(options: masks, selected: from?.email) { option in
                from = option.address
                isChoosingMask = false
            }
        }
    }

    private var identities: [SenderOption] {
        options.filter { option in
            if case .masked = option.kind { return false }
            return true
        }
    }

    private var masks: [SenderOption] {
        options.filter { option in
            if case .masked = option.kind { return true }
            return false
        }
    }

    private func isCurrent(_ option: SenderOption) -> Bool {
        option.address.email.lowercased() == from?.email.lowercased()
    }

    @ViewBuilder private var currentLabel: some View {
        HStack(spacing: 4) {
            if let from, masks.contains(where: { $0.id == from.email.lowercased() }) {
                Image(systemName: "theatermasks")
                    .imageScale(.small)
            }
            Text(from.map(Self.title) ?? "Choose an Address")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// "Alex Berg <alex@fastmail.com>", or the bare address.
    static func title(of address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }
}

/// The masked addresses to send from, searchable: enabled ones first, each with its state, and a note on those
/// Fastmail has no sending identity for.
struct MaskedSenderList: View {
    let options: [SenderOption]
    let selected: String?
    let choose: (SenderOption) -> Void

    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search masked addresses", text: $search)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { option in
                        Button {
                            choose(option)
                        } label: {
                            MaskedSenderRow(option: option, isSelected: option.id == selected?.lowercased())
                        }
                        .buttonStyle(.plain)
                    }
                    if visible.isEmpty {
                        Text("No masked addresses match.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 320)
            Text("Fastmail sends from a masked address only when it is one of your sending addresses.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 360)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var visible: [SenderOption] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return options }
        return options.filter { $0.address.email.localizedCaseInsensitiveContains(query) }
    }
}

struct MaskedSenderRow: View {
    let option: SenderOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : "theatermasks")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.address.email)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(option.needsSendingIdentity ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var note: String? {
        var parts: [String] = []
        if case .masked(_, let state) = option.kind, state != .enabled { parts.append(state.label) }
        if option.needsSendingIdentity { parts.append("No sending identity") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
