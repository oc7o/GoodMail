import GoodMailCore
import JMAPKit
import SwiftUI

/// Sheet for creating a masked address. The new address is copied to the clipboard.
struct MaskedEmailEditor: View {
    let model: MailModel

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var website = ""
    @State private var prefix = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $description, prompt: Text("What is this address for?"))
                    TextField("Website", text: $website, prompt: Text("https://example.com"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }
                Section {
                    TextField("Prefix", text: $prefix, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text(isPrefixValid
                        ? "The address starts with this, followed by random characters."
                        : "Use up to 64 lowercase letters, digits and underscores.")
                        .foregroundStyle(isPrefixValid ? Color.secondary : Color.red)
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Masked Email")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(!isPrefixValid || isCreating)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 320)
        #endif
    }

    private var isPrefixValid: Bool {
        prefix.isEmpty || MaskedEmail.isValidPrefix(prefix)
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let created = try await model.createMaskedEmail(MaskedEmail.Create(
                    forDomain: website.trimmingCharacters(in: .whitespaces).nonEmpty,
                    description: description.trimmingCharacters(in: .whitespaces).nonEmpty,
                    emailPrefix: prefix.nonEmpty))
                Pasteboard.copy(created.email)
                model.selectedMaskedEmailID = created.id
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
