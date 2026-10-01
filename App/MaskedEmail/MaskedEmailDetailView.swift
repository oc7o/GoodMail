import GoodMailCore
import JMAPKit
import SwiftUI

struct MaskedEmailDetailView: View {
    let model: MailModel
    let masked: MaskedEmail

    @State private var description = ""
    @State private var didCopy = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Address") {
                    HStack {
                        Text(masked.email)
                            .textSelection(.enabled)
                        Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                            Pasteboard.copy(masked.email)
                            didCopy = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                LabeledContent("Status", value: masked.state.label)
                TextField("Description", text: $description)
                    .onSubmit(saveDescription)
            } footer: {
                Text(masked.state.explanation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                if let site = masked.forDomain?.nonEmpty {
                    LabeledContent("Website", value: site)
                }
                if let created = masked.createdAt {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                if let creator = masked.createdBy?.nonEmpty {
                    LabeledContent("Created by", value: creator)
                }
                LabeledContent(
                    "Last mail", value: masked.lastMessageAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }

            Section {
                Button("Show Mail to This Address", systemImage: "magnifyingglass") {
                    model.showMail(to: masked.email)
                }
                if masked.state == .enabled || masked.state == .pending {
                    Button("Disable Address", systemImage: "pause.circle") { setState(.disabled) }
                } else {
                    Button("Enable Address", systemImage: "play.circle") { setState(.enabled) }
                }
                if masked.state != .deleted {
                    Button("Delete Address", systemImage: "trash", role: .destructive) { setState(.deleted) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(masked.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { description = masked.description ?? "" }
        .onDisappear(perform: saveDescription)
    }

    private func setState(_ state: MaskedEmail.State) {
        Task { await model.setMaskedEmailState(state, id: masked.id) }
    }

    private func saveDescription() {
        guard description != masked.description ?? "" else { return }
        Task { await model.setMaskedEmailDescription(description, id: masked.id) }
    }
}

extension MaskedEmail.State {
    var explanation: String {
        switch self {
        case .pending: "Not used yet. Fastmail removes pending addresses that receive no mail within 24 hours."
        case .enabled: "Mail to this address is delivered to your inbox."
        case .disabled: "Mail to this address goes straight to Trash."
        case .deleted: "Mail to this address is rejected. You can enable it again at any time."
        default: ""
        }
    }
}

/// Shown on a message that arrived through a masked address, with the actions you want right then.
struct MaskedEmailBadge: View {
    let model: MailModel
    let masked: MaskedEmail

    var body: some View {
        Menu {
            Section(masked.email) {
                Button("Copy Address", systemImage: "doc.on.doc") { Pasteboard.copy(masked.email) }
                Button("Show Mail to This Address", systemImage: "magnifyingglass") {
                    model.showMail(to: masked.email)
                }
                Button("Manage Address", systemImage: "theatermasks") {
                    model.selectedMaskedEmailID = masked.id
                    model.destination = .maskedEmail
                }
            }
            if masked.state == .enabled || masked.state == .pending {
                Button("Disable Address", systemImage: "pause.circle", role: .destructive) {
                    Task { await model.setMaskedEmailState(.disabled, id: masked.id) }
                }
            } else {
                Button("Enable Address", systemImage: "play.circle") {
                    Task { await model.setMaskedEmailState(.enabled, id: masked.id) }
                }
            }
        } label: {
            Label(
                masked.state == .enabled ? "Masked · \(masked.label)" : "Masked · \(masked.label) (\(masked.state.label))",
                systemImage: "theatermasks")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
    }
}
