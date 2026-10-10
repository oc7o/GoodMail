import DemoAccount
import Foundation
import GoodMailCore
import JMAPKit
import MailCompose
import MailStore
import Observation
import Security

/// Top-level app state: whether we're signed in, and the account's mail and services.
@MainActor
@Observable
final class AppModel {
    enum State {
        case loading
        case signedOut
        case signedIn(MailAccount)
    }

    enum SignInError: LocalizedError {
        case invalidToken
        case missingScope(String)
        case network(String)
        /// Replace Token: the new token belongs to another Fastmail account (D18).
        case otherAccount
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                "Fastmail didn't accept this token. Check that you copied all of it and that it hasn't been revoked."
            case .missingScope(let scope):
                "This token is missing the \(scope) scope. Create a new token with the scopes listed above."
            case .network(let message):
                "Couldn't reach Fastmail: \(message)"
            case .otherAccount:
                "This token belongs to another Fastmail account. To use that account, sign out first, then sign in "
                    + "with the new token."
            case .notSignedIn:
                "Sign in to GoodMail first."
            }
        }
    }

    private(set) var state: State = .loading
    /// The local copy couldn't be opened, so it was moved aside and a new one started (D36); shown once.
    var storeWasMovedAside = false
    /// What Sign Out would delete, while the user decides (D36).
    var pendingSignOut: UnsentSummary?

    private let keychain = Keychain(service: "dev.goodmail.GoodMail")
    private let tokenKey = "fastmail-api-token"
    private nonisolated static let storeKeyName = "mail-store-key"
    /// The account whose mail is on disk.
    private static let storeAccountDefaultsKey = "storeAccountID"
    /// Demo mode: every client, a replacement token's included, talks to this server instead of Fastmail.
    private var demoServer: DemoTransport?

    func restore() {
        guard case .loading = state else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demo") {
            openDemoAccount()
            return
        }
        #endif
        if let token = try? keychain.read(tokenKey), !token.isEmpty, let store = try? openStore() {
            state = .signedIn(makeAccount(client: JMAPClient(token: token), store: store))
        } else {
            state = .signedOut
        }
    }

    #if DEBUG
    /// The demo account (`-demo YES`). The render harness passes its own server, clock, network and contacts.
    func openDemoAccount(
        server: DemoTransport = DemoTransport(), clock: any OutboxClock = SystemOutboxClock(),
        network: any NetworkPathSource = SystemNetworkPath(), contacts: any ContactsSource = SystemContacts()
    ) {
        guard let store = try? MailStore(now: { clock.now }) else {
            state = .signedOut
            return
        }
        demoServer = server
        state = .signedIn(makeAccount(
            client: JMAPClient(token: "demo", transport: server), store: store, clock: clock, network: network,
            contacts: contacts))
    }
    #endif

    /// Validates the token against the JMAP session and stores it on success.
    func signIn(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = makeClient(token: token)
        let session = try await validatedSession(of: client)

        // Whatever is left on disk belongs to an earlier sign-in. Only the same account may keep it,
        // along with any changes it couldn't send before its token stopped working.
        let accountID = try? session.primaryAccountId(for: Capability.mail)
        if accountID == nil || UserDefaults.standard.string(forKey: Self.storeAccountDefaultsKey) != accountID {
            MailStore.destroy(at: Self.storeURL)
        }
        let store = try openStore()
        try keychain.write(token, for: tokenKey)
        UserDefaults.standard.set(accountID, forKey: Self.storeAccountDefaultsKey)
        state = .signedIn(makeAccount(client: client, store: store))
    }

    /// Replace Token (D18): a new token for the same account, say one that may send. The store, drafts and
    /// outbox stay; push, the session, the identities and the outbox start over with the new token.
    func replaceToken(_ token: String) async throws {
        guard case .signedIn(let account) = state else { throw SignInError.notSignedIn }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = try await validatedSession(of: makeClient(token: token))
        let current = account.mail.account?.mailAccountID
            ?? UserDefaults.standard.string(forKey: Self.storeAccountDefaultsKey)
        guard let accountID = try? session.primaryAccountId(for: Capability.mail), accountID == current else {
            throw SignInError.otherAccount
        }
        if demoServer == nil { try keychain.write(token, for: tokenKey) }
        await account.mail.client.setToken(token)
        await account.mail.tokenChanged()
    }

    /// The session of a token that is good enough to sign in with: Email and Masked Email (Email submission is
    /// optional; without it Send explains what is missing).
    private func validatedSession(of client: JMAPClient) async throws -> Session {
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
        return session
    }

    private func makeClient(token: String) -> JMAPClient {
        if let demoServer { return JMAPClient(token: token, transport: demoServer) }
        return JMAPClient(token: token)
    }

    // MARK: Signing out

    /// Sign Out…: signs out at once when nothing would be lost, else asks first (D36).
    func beginSignOut() async {
        guard case .signedIn(let account) = state else { return }
        let summary = await account.mail.unsentSummary()
        if summary.isEmpty {
            signOut()
        } else {
            pendingSignOut = summary
        }
    }

    /// Forgets the account: the token, the stored mail with what waits to be sent, the key that could decrypt
    /// it, and every decrypted copy of an attachment.
    func signOut() {
        pendingSignOut = nil
        if case .signedIn(let account) = state { account.stop() }
        TemporaryFiles.shared.purgeAllNow()
        BackgroundSending.cancelScheduledWork()
        // The demo account lives in memory; the real account's token and mail on this device aren't its to delete.
        if demoServer == nil {
            try? keychain.delete(tokenKey)
            try? keychain.delete(Self.storeKeyName)
            MailStore.destroy(at: Self.storeURL)
            UserDefaults.standard.removeObject(forKey: Self.storeAccountDefaultsKey)
        }
        demoServer = nil
        state = .signedOut
    }

    /// Fastmail stopped accepting the token. The stored mail stays, so that changes still waiting to
    /// be sent go out once the same account signs in again.
    private func tokenRejected() {
        if case .signedIn(let account) = state { account.stop() }
        TemporaryFiles.shared.purgeAllNow()
        if demoServer == nil { try? keychain.delete(tokenKey) }
        demoServer = nil
        state = .signedOut
    }

    // MARK: Background

    /// A background task's turn (D35): sends what waits, whether or not a window ever started the account, and
    /// asks to run again while anything is left.
    func sendInBackground() async {
        restore()
        guard case .signedIn(let account) = state else { return }
        let remains = await account.mail.sendPendingMail()
        if remains { BackgroundSending.schedule(for: account.mail.outbox) }
    }

    private func makeAccount(
        client: JMAPClient, store: MailStore, clock: any OutboxClock = SystemOutboxClock(),
        network: any NetworkPathSource = SystemNetworkPath(), contacts: any ContactsSource = SystemContacts()
    ) -> MailAccount {
        let mail = MailModel(
            client: client, store: store, clock: clock, network: network,
            backgroundActivity: BackgroundSending.makeActivity()
        ) { [weak self] in self?.tokenRejected() }
        let unsubscriber: Unsubscriber
        if let demoServer {
            // The demo newsletter's one-click URL is answered by the demo server, and its .example host
            // resolves nowhere, so the public-address check gets a fixed answer.
            unsubscriber = Unsubscriber(
                client: client, store: store, oneClick: demoServer, resolver: FixedHostResolver(["93.184.216.34"]))
        } else {
            unsubscriber = Unsubscriber(client: client, store: store)
        }
        return MailAccount(
            mail: mail, store: store, attachments: AttachmentCenter(client: client, store: store),
            recipients: RecipientDirectory(store: store, contacts: contacts), unsubscriber: unsubscriber)
    }

    // MARK: Stored mail

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "GoodMail/Mail.sqlite")
    }

    /// Opens the encrypted mail store. A store that can't be opened may hold mail that was never sent, so it is
    /// moved aside, never deleted (D36), and a new one is started; the key stays, so a later version can still
    /// read the old copy.
    private func openStore() throws -> MailStore {
        let keychain = keychain
        func open() throws -> MailStore {
            try MailStore(url: Self.storeURL) { try Self.storeKey(in: keychain) }
        }
        // A Keychain that can't be read right now, say before first unlock, is no reason to give up
        // those unsent changes.
        _ = try Self.storeKey(in: keychain)

        let store: MailStore
        do {
            store = try open()
        } catch {
            MailStore.moveAside(at: Self.storeURL)
            store = try open()
            storeWasMovedAside = true
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

/// One signed-in account: its mail, and the services every window of it shares, one of each per account.
@MainActor
@Observable
final class MailAccount {
    let mail: MailModel
    let store: MailStore
    let attachments: AttachmentCenter
    let recipients: RecipientDirectory
    let unsubscriber: Unsubscriber
    /// The Masked Email editor is up, e.g. after ⌃⌘N.
    var isCreatingMaskedEmail = false
    /// The message sent last, for a few seconds: offline, the main window says when it goes out (§3.10).
    private(set) var lastSent: SentMessage?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// The composers on screen, so that quitting can commit what is still typed in their recipient fields.
    @ObservationIgnored private var flows: [WeakFlow] = []

    private struct WeakFlow {
        weak var flow: ComposeFlow?
    }

    struct SentMessage: Equatable {
        let id: UUID
        let subject: String
        let at: Date
    }

    init(
        mail: MailModel, store: MailStore, attachments: AttachmentCenter, recipients: RecipientDirectory,
        unsubscriber: Unsubscriber
    ) {
        self.mail = mail
        self.store = store
        self.attachments = attachments
        self.recipients = recipients
        self.unsubscriber = unsubscriber
    }

    /// Starts sync, push and the outbox once, for whichever window comes first, the main one or a restored
    /// composer; it runs until sign-out, not only as long as that window.
    func start() {
        guard starting == nil else { return }
        starting = Task { await mail.start() }
    }

    func stop() {
        starting?.cancel()
        mail.stop()
    }

    func register(_ flow: ComposeFlow) {
        flows.removeAll { $0.flow == nil || $0.flow === flow }
        flows.append(WeakFlow(flow: flow))
    }

    /// Addresses typed in recipient fields but not yet tokens become recipients, as Return would make them, so
    /// that the last save before quitting has them (P6).
    func commitTypedRecipients() {
        for case let flow? in flows.map(\.flow) { flow.commitEntries() }
    }

    func noteSent(_ id: UUID, subject: String) {
        let sent = SentMessage(id: id, subject: subject, at: Date())
        lastSent = sent
        Task {
            try? await Task.sleep(for: .seconds(Self.offlineNoticeDuration))
            if lastSent == sent { lastSent = nil }
        }
    }

    /// Sent within the last few seconds and waiting for a connection: "Will send when you're back online".
    func messageWaitingOffline(at date: Date) -> SentMessage? {
        guard let lastSent, date.timeIntervalSince(lastSent.at) < Self.offlineNoticeDuration else { return nil }
        let item = mail.outbox.items.first { $0.id == lastSent.id }
        guard case .waiting(.offline)? = item?.state else { return nil }
        return lastSent
    }

    static let offlineNoticeDuration: TimeInterval = 8

    /// The image a quoted original shows for a `cid:` URL: the stored copy, else downloaded and kept, like the
    /// reading pane's.
    func inlineImage(cid: String, among parts: [OriginalMessage.InlinePart]) async -> (data: Data, mimeType: String)? {
        guard let part = parts.first(where: { $0.cid == cid }) else { return nil }
        if let data = try? await store.inlineImageData(blobId: part.blobId) { return (data, part.type) }
        guard let data = try? await mail.client.download(blobId: part.blobId, type: part.type, name: part.name ?? "image")
        else { return nil }
        try? await store.storeInlineImageData(data, blobId: part.blobId, evictingBeyond: MailStore.inlineImageCacheLimit)
        return (data, part.type)
    }
}
