import SwiftUI

/// Replace Token (D18): a new API token for the same account, for instance one that may send. The stored mail,
/// the drafts and the Outbox stay; a token of another account is refused.
struct ReplaceTokenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isReplacing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // One literal, so that Text reads it as markdown.
                    Text("""
                        Create a new token in Fastmail under **\(OnboardingView.tokenSettingsPath)** with the \
                        **Email**, **Email submission** and **Masked Email** scopes, then paste it here.
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Open Fastmail token settings", destination: OnboardingView.tokenSettingsURL)
                }
                Section {
                    SecureField("New API token", text: $token)
                        .textContentType(.password)
                        .onSubmit(replace)
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Your mail, drafts and the Outbox stay as they are. You can delete the old token in "
                         + "Fastmail afterwards.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Replace Token")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isReplacing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Replace", action: replace)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 380)
        #endif
    }

    private func replace() {
        guard !isReplacing, !token.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isReplacing = true
        error = nil
        Task {
            defer { isReplacing = false }
            do {
                try await model.replaceToken(token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
