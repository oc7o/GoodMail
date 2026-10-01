import DemoAccount
import Foundation
import GoodMailCore
import JMAPKit
import Observation

/// Top-level app state: whether we're signed in, and the mail model for the account.
@MainActor
@Observable
final class AppModel {
    enum State {
        case loading
        case signedOut
        case signedIn(MailModel)
    }

    enum SignInError: LocalizedError {
        case invalidToken
        case missingScope(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                "Fastmail didn't accept this token. Check that you copied all of it and that it hasn't been revoked."
            case .missingScope(let scope):
                "This token is missing the \(scope) scope. Create a new token with the scopes listed above."
            case .network(let message):
                "Couldn't reach Fastmail: \(message)"
            }
        }
    }

    private(set) var state: State = .loading

    private let keychain = Keychain(service: "dev.goodmail.GoodMail")
    private let tokenKey = "fastmail-api-token"

    func restore() {
        guard case .loading = state else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demo") {
            state = .signedIn(mailModel(for: JMAPClient(token: "demo", transport: DemoTransport())))
            return
        }
        #endif
        if let token = try? keychain.read(tokenKey), !token.isEmpty {
            state = .signedIn(mailModel(for: JMAPClient(token: token)))
        } else {
            state = .signedOut
        }
    }

    /// Validates the token against the JMAP session and stores it on success.
    func signIn(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = JMAPClient(token: token)
        let session: Session
        do {
            session = try await client.session()
        } catch JMAPError.unauthorized {
            throw SignInError.invalidToken
        } catch {
            throw SignInError.network(error.localizedDescription)
        }

        for (capability, scope) in [(Capability.mail, "Email"), (Capability.maskedEmail, "Masked Email")]
        where !session.supports(capability) {
            throw SignInError.missingScope(scope)
        }

        try keychain.write(token, for: tokenKey)
        state = .signedIn(mailModel(for: client))
    }

    func signOut() {
        try? keychain.delete(tokenKey)
        state = .signedOut
    }

    private func mailModel(for client: JMAPClient) -> MailModel {
        MailModel(client: client) { [weak self] in self?.signOut() }
    }
}
