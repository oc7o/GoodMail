import DemoAccount
import Foundation
import GoodMailCore
import JMAPKit
import MailStore
import Observation
import Security

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
    private nonisolated static let storeKeyName = "mail-store-key"

    func restore() {
        guard case .loading = state else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demo"), let store = try? MailStore() {
            state = .signedIn(mailModel(client: JMAPClient(token: "demo", transport: DemoTransport()), store: store))
            return
        }
        #endif
        if let token = try? keychain.read(tokenKey), !token.isEmpty, let store = try? openStore() {
            state = .signedIn(mailModel(client: JMAPClient(token: token), store: store))
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

        // Whatever is left on disk belongs to an earlier sign-in, possibly a different account.
        MailStore.destroy(at: Self.storeURL)
        let store = try openStore()
        try keychain.write(token, for: tokenKey)
        state = .signedIn(mailModel(client: client, store: store))
    }

    /// Forgets the account: the token, the stored mail and the key that could decrypt it.
    func signOut() {
        if case .signedIn(let mail) = state { mail.stop() }
        try? keychain.delete(tokenKey)
        try? keychain.delete(Self.storeKeyName)
        MailStore.destroy(at: Self.storeURL)
        state = .signedOut
    }

    private func mailModel(client: JMAPClient, store: MailStore) -> MailModel {
        MailModel(client: client, store: store) { [weak self] in self?.signOut() }
    }

    // MARK: Stored mail

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "GoodMail/Mail.sqlite")
    }

    /// Opens the encrypted mail store. It only holds what the server has too, so a store that can't
    /// be read (say, because its key is gone from the Keychain) is thrown away and started afresh.
    private func openStore() throws -> MailStore {
        let keychain = keychain
        func open() throws -> MailStore {
            try MailStore(url: Self.storeURL) { try Self.storeKey(in: keychain) }
        }

        let store: MailStore
        do {
            store = try open()
        } catch {
            MailStore.destroy(at: Self.storeURL)
            store = try open()
        }
        // The key never leaves this device, so a backed-up copy would be dead weight.
        var directory = Self.storeURL.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return store
    }

    private nonisolated static func storeKey(in keychain: Keychain) throws -> Data {
        if let hex = try keychain.read(storeKeyName), hex.count == 64 {
            let bytes = stride(from: 0, to: 64, by: 2).compactMap { offset in
                UInt8(hex.dropFirst(offset).prefix(2), radix: 16)
            }
            if bytes.count == 32 { return Data(bytes) }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
        try keychain.write(bytes.map { String(format: "%02x", $0) }.joined(), for: storeKeyName)
        return Data(bytes)
    }
}
