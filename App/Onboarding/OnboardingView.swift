import SwiftUI

/// Sign-in with a Fastmail API token.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var isSigningIn = false
    @State private var error: String?

    static let tokenSettingsURL = URL(string: "https://app.fastmail.com/settings/security/tokens")!
    static let tokenSettingsPath = "Settings → Privacy & Security → Connected apps & API tokens → Manage API tokens"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                steps
                tokenField
                privacyNote
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Welcome to GoodMail")
                .font(.largeTitle.bold())
            Text("Connect your Fastmail account with an API token.")
                .foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Open **\(Self.tokenSettingsPath)** in Fastmail and create a new token.")
            } icon: {
                Image(systemName: "1.circle.fill")
            }
            Label {
                // One literal, so that Text reads it as markdown.
                Text("""
                    Give it the **Email**, **Email submission** and **Masked Email** scopes. Read-only access is not \
                    enough, and without Email submission you can read and write drafts but not send.
                    """)
            } icon: {
                Image(systemName: "2.circle.fill")
            }
            Label {
                Text("Copy the token and paste it below.")
            } icon: {
                Image(systemName: "3.circle.fill")
            }
            Link("Open Fastmail token settings", destination: Self.tokenSettingsURL)
                .padding(.leading, 32)
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("API token", text: $token)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit(signIn)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button(action: signIn) {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)
        }
    }

    private var privacyNote: some View {
        Label(
            "Your token stays in this device's Keychain. GoodMail talks only to Fastmail and collects no analytics.",
            systemImage: "lock.shield"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await model.signIn(token: token)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
