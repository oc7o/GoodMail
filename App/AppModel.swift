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
        /// Signed in, but the mail on this device can't be opened right now (no space, the Keychain locked).
        /// Nothing was moved or deleted; Try Again opens it once that has passed.
        case unavailable(String)
    }

    enum SignInError: LocalizedError {
        case invalidToken
        case missingScope(String)
        case network(String)
        /// Replace Token: the new token belongs to another Fastmail account (D18).
        case otherAccount
        case notSignedIn
        /// Signing in with another account would delete what the account used before left unsent on this device
        /// (D36): the user is asked first. `nil` when the stored mail couldn't be checked.
        case unsentMailOfOtherAccount(UnsentSummary?)
        /// The mail on this device can't be opened right now; nothing was moved or deleted.
        case storeUnavailable(String)

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
            case .unsentMailOfOtherAccount(let summary):
                UnsentMailText.otherAccount(summary)
            case .storeUnavailable(let reason):
                reason
            }
        }
    }

    private(set) var state: State = .loading
    /// The local copy couldn't be opened, so it was moved aside and a new one started (D36). Kept until the
    /// alert saying so was dismissed, even if the app ends before it could show.
    var storeWasMovedAside: Bool {
        didSet { UserDefaults.standard.set(storeWasMovedAside, forKey: Self.storeMovedAsideDefaultsKey) }
    }

    private let keychain = Keychain(service: "dev.goodmail.GoodMail")
    private let tokenKey = "fastmail-api-token"
    private nonisolated static let storeKeyName = "mail-store-key"
    /// The account whose mail is on disk.
    private static let storeAccountDefaultsKey = "storeAccountID"
    private static let storeMovedAsideDefaultsKey = "storeMovedAside"
    /// Demo mode: every client, a replacement token's included, talks to this server instead of Fastmail.
    private var demoServer: DemoTransport?

    init() {
        storeWasMovedAside = UserDefaults.standard.bool(forKey: Self.storeMovedAsideDefaultsKey)
    }

    func restore() {
        guard case .loading = state else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demo") {
            openDemoAccount()
            return
        }
        #endif
        do {
            guard let token = try keychain.read(tokenKey), !token.isEmpty else {
                state = .signedOut
                return
            }
            state = .signedIn(makeAccount(client: JMAPClient(token: token), store: try openStore()))
        } catch {
            state = .unavailable(Self.explanation(of: error))
        }
    }

    /// Try Again, when the stored mail couldn't be opened.
    func retryRestore() {
        guard case .unavailable = state else { return }
        state = .loading
        restore()
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
    ///
    /// Mail left on this device by another account is deleted, but unsent mail never without asking (D36): unless
    /// `deletingUnsentMailOfOtherAccount`, that throws `SignInError.unsentMailOfOtherAccount` for the user to
    /// decide.
    func signIn(token: String, deletingUnsentMailOfOtherAccount: Bool = false) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = makeClient(token: token)
        let session = try await validatedSession(of: client)

        // Whatever is left on disk belongs to an earlier sign-in. Only the same account may keep it,
        // along with any changes it couldn't send before its token stopped working.
        let accountID = try? session.primaryAccountId(for: Capability.mail)
        if accountID == nil || UserDefaults.standard.string(forKey: Self.storeAccountDefaultsKey) != accountID {
            if !deletingUnsentMailOfOtherAccount, FileManager.default.fileExists(atPath: Self.storeURL.path) {
                let keychain = keychain
                let unsent = await Self.unsentMail(inStoreAt: Self.storeURL) { try Self.storeKey(in: keychain) }
                if unsent.map({ !$0.isEmpty }) ?? true { throw SignInError.unsentMailOfOtherAccount(unsent) }
            }
            MailStore.destroy(at: Self.storeURL)
        }
        let store: MailStore
        do {
            store = try openStore()
        } catch {
            throw SignInError.storeUnavailable(Self.explanation(of: error))
        }
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
        // Messages that failed only because the old token couldn't send go out now: Send was pressed for each,
        // and replacing the token is what their row asked for. Nothing of them reached Fastmail (a 403).
        guard account.mail.sendAvailability == .available else { return }
        for item in account.mail.outbox.items where item.state == .failed(.tokenLacksSubmission) {
            account.mail.outbox.retry(item.id)
        }
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

    /// Sign Out…: signs out at once when nothing would be lost. Otherwise returns what would be, for the window
    /// that asked to show its confirmation (D36).
    func beginSignOut() async -> UnsentSummary? {
        guard case .signedIn(let account) = state else { return nil }
        let summary = await account.mail.unsentSummary()
        guard summary.isEmpty else { return summary }
        signOut()
        return nil
    }

    /// Forgets the account: the token, the stored mail with what waits to be sent, the key that could decrypt
    /// it, and every decrypted copy of an attachment.
    func signOut() {
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
        if case .unavailable = state { retryRestore() } else { restore() }
        if case .unavailable = state {
            // The stored mail can't be opened yet (say, no space): a later turn tries again.
            BackgroundSending.schedule(BackgroundSending.Plan(refresh: true, processing: false))
            return
        }
        guard case .signedIn(let account) = state else { return }
        // The next turn is asked for before this one works: iOS can end a turn early, and then nothing after the
        // work runs. The outbox isn't known yet when the turn launched the app, so both kinds are asked for.
        BackgroundSending.schedule(BackgroundSending.Plan(refresh: true, processing: true))
        // When iOS ends the turn it cancels this task; returning then lets the turn end in time. What was cut
        // short is picked up from its persisted state.
        _ = await waitForWork { _ = await account.mail.sendPendingMail() }
        BackgroundSending.schedule(for: account.mail.outbox)
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

    /// Opens the encrypted mail store; see `openStore(at:key:movedAside:)`. The key stays in the Keychain, so a
    /// later version can still read a copy that was moved aside.
    private func openStore() throws -> MailStore {
        let keychain = keychain
        // A Keychain that can't be read right now, say before first unlock, is no reason to give up
        // those unsent changes.
        _ = try Self.storeKey(in: keychain)
        let store = try Self.openStore(at: Self.storeURL, key: { try Self.storeKey(in: keychain) }) {
            storeWasMovedAside = true
        }
        // The key never leaves this device, so a backed-up copy would be dead weight.
        var directory = Self.storeURL.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return store
    }

    /// Opens the store at `url`, creating it if needed.
    ///
    /// A store that is damaged, or that this device's key doesn't open, may hold mail that was never sent: it is
    /// moved aside, never deleted, and a new one is started (D36); `movedAside` runs as soon as it moved. Every
    /// other error leaves the files where they are and throws: no space, a file the system won't open yet, a
    /// migration this version can't do. Those pass, or a later version fixes them, and the mail is still there.
    static func openStore(
        at url: URL, key: @escaping @Sendable () throws -> Data, movedAside: () -> Void
    ) throws -> MailStore {
        do {
            return try MailStore(url: url, key: key)
        } catch where isUnreadable(error) {
            // A copy that couldn't be moved must not be opened afresh in its place.
            guard MailStore.moveAside(at: url) != nil, !FileManager.default.fileExists(atPath: url.path) else {
                throw error
            }
            movedAside()
            do {
                return try MailStore(url: url, key: key)
            } catch {
                // This attempt's database holds nothing. Left in place, a later move aside could push the copy
                // just kept out of Unreadable/, which keeps one set only.
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
                }
                throw error
            }
        }
    }

    /// What the store at `url` holds that was never sent or never reached Fastmail (D36), as Sign Out counts it;
    /// `nil` when it can't be read.
    static func unsentMail(inStoreAt url: URL, key: @escaping @Sendable () throws -> Data) async -> UnsentSummary? {
        guard let store = try? MailStore(url: url, key: key) else { return nil }
        let mail = MailModel(client: JMAPClient(token: ""), store: store, syncsInBackground: false) {}
        return await mail.unsentSummary()
    }

    /// A damaged file, or one that isn't a database with this key: SQLite's CORRUPT and NOTADB, from GRDB.
    nonisolated static func isUnreadable(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == "GRDB.DatabaseError" && [11, 26].contains(error.code & 0xFF)
    }

    /// What the unavailable screen says.
    nonisolated static func explanation(of error: any Error) -> String {
        let nsError = error as NSError
        let isFull = (nsError.domain == "GRDB.DatabaseError" && nsError.code & 0xFF == 13)
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
        if isFull { return "There isn't enough free space on this device. Free up some space, then try again." }
        if let failure = error as? Keychain.Failure { return failure.localizedDescription }
        return "GoodMail couldn't open the mail stored on this device (\(error.localizedDescription))."
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
        // A download finishing after sign-out would make a decrypted copy that the sign-out purge never saw (D23).
        for blobId in attachments.downloads.keys {
            attachments.cancelDownload(blobId: blobId)
        }
    }

    func register(_ flow: ComposeFlow) {
        flows.removeAll { $0.flow == nil || $0.flow === flow }
        flows.append(WeakFlow(flow: flow))
    }

    /// Whether a composer is on screen, with edits that may not be saved yet.
    var hasOpenComposers: Bool {
        flows.contains { $0.flow != nil }
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
