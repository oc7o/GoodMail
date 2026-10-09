import Foundation
import ImageIO
import JMAPKit
import MailCompose
import MailPrivacy
import MailStore
import Observation
import UniformTypeIdentifiers

/// Why a message can't be sent as it is.
public enum SendProblem: Error, Equatable, Sendable, LocalizedError {
    case noRecipients, invalidAddresses([String]), noSender, cannotSend(SendAvailability)
    case attachmentsTooLarge(bytes: Int, limit: Int), requestTooLarge(bytes: Int, limit: Int)
    /// A masked address Fastmail has no sending identity for (D21). While GoodMail may create identities, Send
    /// asks the user for consent for exactly this address and tries again with it.
    case needsSendingIdentity(String)
    case attachmentDataLost([String]), inlineForwardIncomplete

    public var errorDescription: String? {
        switch self {
        case .noRecipients:
            "Add a recipient."
        case .invalidAddresses(let addresses):
            "Check \(addresses.joined(separator: ", ")): \(addresses.count == 1 ? "it isn't" : "they aren't") a valid address."
        case .noSender:
            "Choose an address to send from."
        case .cannotSend(.readOnlyAccount):
            "This Fastmail account is read-only."
        case .cannotSend:
            "Your API token can't send mail. Replace it with one that has the Email submission scope."
        case .attachmentsTooLarge(let bytes, let limit):
            "Attachments are \(Self.megabytes(bytes)); Fastmail allows \(Self.megabytes(limit))."
        case .requestTooLarge(_, let limit):
            "The message is too long; Fastmail accepts requests of up to \(Self.megabytes(limit))."
        case .needsSendingIdentity(let address):
            MaskedSendPolicy.createsIdentities
                ? "Fastmail needs a sending identity for \(address). Create it and send?"
                : "Fastmail only lets apps send from a masked address that is a sending address. Add \(address) "
                    + "under Fastmail → Settings → My email addresses."
        case .attachmentDataLost(let names):
            "Attach \(names.joined(separator: ", ")) again: the data is no longer on this device."
        case .inlineForwardIncomplete:
            "The original isn't complete on this device. Forward it as an attachment instead."
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public enum SaveStatus: Equatable, Sendable {
    case unsaved
    /// On this device only, for now.
    case savedLocally
    case savedToServer(Date)
    case failed(String)
}

/// Something the composer has to tell about the draft.
public enum ComposerNotice: Equatable, Sendable, Codable {
    /// Another device changed the draft too; both versions are kept, this one under a new Message-ID (D10).
    case otherVersionKept
    /// Another device sent the message; Close, or Keep as New Message.
    case sentElsewhere
    /// It was deleted elsewhere, and kept here because of changes made on this device.
    case deletedElsewhereRestored
    /// The original is quoted only in part (C20).
    case quoteShortened
    /// Without a connection the original's text isn't available, so it isn't quoted.
    case originalUnavailableOffline
    /// The draft was saved to Fastmail without attachments still uploading (C28).
    case attachmentsNotOnServerYet
}

public enum UploadState: Equatable, Sendable {
    case waiting
    case uploading(Double)
    case uploaded
    case failed(String)
}

/// What to open a composer with.
public enum ComposeRequest: Sendable {
    case new(to: [EmailAddress] = [], subject: String = "", body: AttributedString = AttributedString(), from: EmailAddress? = nil)
    case reply(emailID: String, all: Bool)
    case forward(emailID: String, asAttachment: Bool)
    /// A draft on the server, written here or elsewhere (§2.3).
    case draft(emailID: String)
    /// A composition with a draft row on this device, e.g. after a relaunch.
    case restore(UUID)
    /// A `mailto:` link, from the message it was in if any (C8).
    case mailto(MailtoLink, sourceEmailID: String?)
}

public enum ComposeError: Error, Equatable, Sendable, LocalizedError {
    /// The email or draft isn't there (any more).
    case notFound

    public var errorDescription: String? {
        "The message is no longer available."
    }
}

public enum AttachmentError: Error, Equatable, Sendable, LocalizedError {
    /// A photo whose location can't be removed; it is attached only when the user agrees
    /// (`keepingLocation: true`).
    case locationNotRemovable(String)

    public var errorDescription: String? {
        "This photo's location can't be removed. Attach it with its location?"
    }
}

/// One open composer window or sheet: the message being written, kept saved on the device and in Fastmail's
/// Drafts as it changes (D8), and sent through the outbox.
///
/// Each part of the message is its own observable property, so keystrokes in the body don't redraw the header.
@MainActor
@Observable
public final class Composer: Identifiable {
    public enum Mode: Equatable, Sendable {
        case editing
        /// A draft from another client GoodMail can't edit without loss, shown read-only (D32).
        case preview(Set<MailBodyHTMLReader.Feature>)
    }

    public let id: UUID
    public let kind: MessageDraft.Kind
    public private(set) var mode: Mode
    /// Changing it changes the signature, Reply-To, the identity's automatic Bcc and, with the domain, the
    /// Message-ID (D6, D9, D20). A masked address has no display name.
    public var from: EmailAddress? {
        didSet { if from != oldValue { senderChanged() } }
    }
    public var to: [EmailAddress] {
        didSet { if to != oldValue { edited() } }
    }
    public var cc: [EmailAddress] {
        didSet { if cc != oldValue { edited() } }
    }
    public var bcc: [EmailAddress] {
        didSet { if bcc != oldValue { edited() } }
    }
    public var subject: String {
        didSet { if subject != oldValue { edited() } }
    }
    public var body: AttributedString {
        didSet { if body != oldValue { edited() } }
    }
    public private(set) var attachments: [DraftAttachment]
    public private(set) var quote: QuotedMessage?
    public private(set) var preservedTail: PreservedTail?
    public private(set) var signature: Signature?
    public private(set) var saveStatus: SaveStatus
    public private(set) var notices: [ComposerNotice]
    /// The draft as its client wrote it, shown read-only in preview mode (sanitized by the renderer).
    public private(set) var previewHTML: String?
    public private(set) var previewText: String?
    /// Local attachments whose data is gone (after a blob file reset) and that the server doesn't have.
    private var lostAttachmentIDs: Set<UUID>

    @ObservationIgnored private weak var model: MailModel?
    @ObservationIgnored private(set) var messageID: String
    @ObservationIgnored private var replyTo: [EmailAddress]
    /// Bcc addresses the From identity added by itself, swapped out with it.
    @ObservationIgnored private var automaticBcc: [EmailAddress] = []
    @ObservationIgnored private let inReplyTo: [String]?
    @ObservationIgnored private let references: [String]?
    @ObservationIgnored private let original: OriginalMessage?
    @ObservationIgnored private var includesSignature: Bool
    /// Where the original arrived, for the From warning.
    @ObservationIgnored private let receivedAt: SenderChoice?
    /// The server draft this composer opened, until a row of its own exists.
    @ObservationIgnored private var origin: Outbox.Origin?
    /// Whether the user changed anything; until then nothing is written (D8).
    @ObservationIgnored private(set) var hasEdits: Bool
    @ObservationIgnored private var lastEditAt: Date?
    @ObservationIgnored private var autosavedEdit: Date?
    /// Edits made, and how many of them the last local save took in.
    @ObservationIgnored private var edits = 0
    @ObservationIgnored private var savedEdits = 0
    @ObservationIgnored private var savedRevision: Int64?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var keptAsNew = false

    init(
        model: MailModel, draft: MessageDraft, mode: Mode = .editing, notices: [ComposerNotice] = [],
        receivedAt: SenderChoice? = nil, origin: Outbox.Origin? = nil, preview: (html: String?, text: String?)? = nil,
        restoredRevision: Int64? = nil, saveStatus: SaveStatus = .unsaved, lostAttachments: Set<UUID> = []
    ) {
        let directory = model.senderDirectory
        // A new composition takes on its sender's settings; a saved one keeps what it was saved with. Each
        // property is set once: setting one again here would run its observer and count as an edit.
        let settings = restoredRevision == nil && origin == nil
            ? Self.settings(for: draft.from, directory: directory, bcc: draft.bcc, automaticBcc: [], messageID: draft.messageID)
            : SenderSettings(replyTo: draft.replyTo, bcc: draft.bcc, automaticBcc: [], messageID: draft.messageID)
        self.model = model
        id = draft.id
        kind = draft.kind
        self.mode = mode
        from = draft.from
        to = draft.to
        cc = draft.cc
        bcc = settings.bcc
        subject = draft.subject
        body = draft.body
        attachments = draft.attachments
        quote = draft.original?.quote
        preservedTail = draft.preservedTail
        signature = draft.includesSignature ? directory.signature(for: draft.from?.email) : nil
        self.saveStatus = saveStatus
        self.notices = notices
        previewHTML = preview?.html
        previewText = preview?.text
        lostAttachmentIDs = lostAttachments
        messageID = settings.messageID
        replyTo = settings.replyTo
        automaticBcc = settings.automaticBcc
        inReplyTo = draft.inReplyTo
        references = draft.references
        original = draft.original
        includesSignature = draft.includesSignature
        self.receivedAt = receivedAt
        self.origin = origin
        hasEdits = restoredRevision != nil
        savedRevision = restoredRevision
    }

    /// The message as it stands.
    public var draft: MessageDraft {
        MessageDraft(
            id: id, kind: kind, from: from, messageID: messageID, to: to, cc: cc, bcc: bcc, replyTo: replyTo,
            subject: subject, body: body, attachments: attachments, inReplyTo: inReplyTo, references: references,
            original: original, preservedTail: preservedTail, includesSignature: includesSignature)
    }

    /// Empty → Send is enabled.
    public var problems: [SendProblem] {
        guard let model else { return [.cannotSend(.unknown)] }
        let lost = attachments.filter { lostAttachmentIDs.contains($0.id) }.map(\.name)
        return SendCheck.problems(
            for: draft, availability: model.sendAvailability, account: model.account,
            directory: model.senderDirectory, policy: model.outbox.maskedSending, lostAttachments: lost)
    }

    /// A warning about the sender: a disabled or deleted masked address (D22), a From other than the address the
    /// original arrived at, or a masked forward whose attached original names the address it was delivered to.
    public var senderWarning: String? {
        guard let model, let from else { return nil }
        let directory = model.senderDirectory
        if let masked = directory.maskedEmail(from.email) {
            if masked.state == .disabled { return "\(from.email) is disabled, so replies to it go to Trash." }
            if masked.state == .deleted { return "\(from.email) is deleted, so replies to it are rejected." }
        }
        // The attachment would reveal another address of the user's whatever From says (C19).
        if kind == .forwardAsAttachment, directory.isMasked(from.email) {
            return "The attached message shows the address it was delivered to."
        }
        if let receivedAt, receivedAt.reason != .defaultIdentity, receivedAt.reason != .loginName,
           receivedAt.address.email.lowercased() != from.email.lowercased() {
            let received = receivedAt.address.email
            return "You received this at \(received). Sending from \(from.email) shows \(from.email) to the recipients."
        }
        return nil
    }

    public var attachmentBytes: Int {
        attachments.reduce(0) { $0 + $1.size }
    }

    public var attachmentLimit: Int? {
        model?.account?.maxSizeAttachmentsPerEmail
    }

    /// The upload state of each attachment: what the outbox reports, else whether the server has it.
    public var uploads: [UUID: UploadState] {
        let states = model?.outbox.uploadStates ?? [:]
        return Dictionary(uniqueKeysWithValues: attachments.map { attachment in
            switch attachment.source {
            case .server: (attachment.id, .uploaded)
            case .local: (attachment.id, states[attachment.id] ?? .waiting)
            }
        })
    }

    /// Leaves preview mode to edit a draft from another client; the editor simplifies its formatting, and the
    /// original moves to Trash once the edited version is saved (D32).
    public func editAnyway() {
        guard case .preview = mode else { return }
        mode = .editing
        previewHTML = nil
        previewText = nil
        origin?.movesToTrash = true
    }

    /// A draft that another device sent meanwhile becomes a new message of its own (§2.3); until then, or
    /// until it is closed, nothing of it is saved.
    public func keepAsNewMessage() async {
        guard notices.contains(.sentElsewhere), let model else { return }
        keptAsNew = true
        notices.removeAll { $0 == .sentElsewhere }
        messageID = MessageDraft.newMessageID(domain: from.flatMap { AddressParser.domain(of: $0.email) } ?? "invalid")
        await model.outbox.clearNotice(id)
        edited()
    }

    /// Removes a notice once read. "Sent from another device" needs a decision instead: Close, or
    /// `keepAsNewMessage()`.
    public func dismiss(_ notice: ComposerNotice) {
        guard notice != .sentElsewhere else { return }
        notices.removeAll { $0 == notice }
        Task { await model?.outbox.clearNotice(id) }
    }

    // MARK: Attachments

    /// Attaches a file, reading it a megabyte at a time into the encrypted blob file. A photo loses its location
    /// first; when that can't be done, this throws `AttachmentError.locationNotRemovable` unless the user agreed
    /// to `keepingLocation`.
    public func addAttachment(fileAt url: URL, keepingLocation: Bool = false) async throws {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        let typeIdentifier = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier
            ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        switch try await Self.prepare(fileAt: url, typeIdentifier: typeIdentifier, keepingLocation: keepingLocation) {
        case .file:
            try await attach(name: url.lastPathComponent, typeIdentifier: typeIdentifier) { store, id, draftID, name, type in
                try await store.importOutgoingAttachment(from: url, id: id, draftID: draftID, name: name, type: type)
            }
        case .image(let data, let cleanedType):
            try await attach(data, name: url.lastPathComponent, typeIdentifier: typeIdentifier, cleanedType: cleanedType)
        }
    }

    /// Attaches data such as a pasted image or a scanned document, a photo without its location (see
    /// `addAttachment(fileAt:keepingLocation:)`).
    public func addAttachment(
        _ data: Data, name: String, typeIdentifier: String, keepingLocation: Bool = false
    ) async throws {
        switch try await Self.prepare(data, typeIdentifier: typeIdentifier, keepingLocation: keepingLocation) {
        case .file:
            try await attach(data, name: name, typeIdentifier: typeIdentifier, cleanedType: typeIdentifier)
        case .image(let cleaned, let cleanedType):
            try await attach(cleaned, name: name, typeIdentifier: typeIdentifier, cleanedType: cleanedType)
        }
    }

    public func removeAttachment(_ id: UUID) async {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        lostAttachmentIDs.remove(id)
        edited()
        if attachment.source == .local, let model {
            await saveLocally()
            try? await model.store.deleteOutgoingAttachment(id: id.uuidString)
        }
    }

    private enum Prepared {
        case file
        case image(Data, typeIdentifier: String)
    }

    /// Sniffs the file, since its name may not say it is an image, and strips a photo's location.
    @concurrent
    private static func prepare(fileAt url: URL, typeIdentifier: String, keepingLocation: Bool) async throws -> Prepared {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) != nil else {
            return .file
        }
        return try strip(try Data(contentsOf: url), typeIdentifier: typeIdentifier, keepingLocation: keepingLocation)
    }

    @concurrent
    private static func prepare(_ data: Data, typeIdentifier: String, keepingLocation: Bool) async throws -> Prepared {
        try strip(data, typeIdentifier: typeIdentifier, keepingLocation: keepingLocation)
    }

    private nonisolated static func strip(_ data: Data, typeIdentifier: String, keepingLocation: Bool) throws -> Prepared {
        switch PhotoMetadata.withoutLocation(data, typeIdentifier: typeIdentifier) {
        case .notAnImage: return .file
        case .image(let cleaned, let type): return .image(cleaned, typeIdentifier: type)
        case .locationNotRemovable:
            guard keepingLocation else { throw AttachmentError.locationNotRemovable(typeIdentifier) }
            return .image(data, typeIdentifier: typeIdentifier)
        }
    }

    private func attach(_ data: Data, name: String, typeIdentifier: String, cleanedType: String) async throws {
        // A photo converted to another format gets that format's extension and MIME type.
        var name = name
        if cleanedType != typeIdentifier, let fileExtension = UTType(cleanedType)?.preferredFilenameExtension {
            name = (name as NSString).deletingPathExtension + "." + fileExtension
        }
        try await attach(name: name, typeIdentifier: cleanedType) { store, id, draftID, name, type in
            try await store.addOutgoingAttachment(data, id: id, draftID: draftID, name: name, type: type)
        }
    }

    private func attach(
        name: String, typeIdentifier: String,
        write: (MailStore, String, String, String, String) async throws -> OutgoingAttachment
    ) async throws {
        guard let model, !isClosed, mode == .editing else { return }
        let type = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
        let name = name.isEmpty ? SafeFilename.make(nil, mimeType: type) : name
        // The bytes belong to the draft's row, which has to exist first.
        edited()
        await saveLocally()
        let attachmentID = UUID()
        let stored = try await write(model.store, attachmentID.uuidString, id.uuidString, name, type)
        attachments.append(DraftAttachment(id: attachmentID, name: name, type: type, size: stored.size, source: .local))
        await saveLocally()
        model.outbox.startUploads(id.uuidString)
    }

    // MARK: Sending and saving

    /// Sends the message through the outbox and closes the composer; throws a `SendProblem` instead when it
    /// can't be sent as it is. `address` is the exact masked address the user agreed to create a sending
    /// identity for, when GoodMail may (D21, C24).
    public func send(consentingToSendingIdentityFor address: String? = nil) async throws {
        guard let model, !isClosed else { return }
        editAnyway()
        if let problem = problems.first { throw problem }
        autosave?.cancel()
        autosave = nil
        // The row, with a server draft this composer opened, exists before the message joins the outbox.
        hasEdits = true
        if isDirty || savedRevision == nil { await saveLocally() }
        try await model.outbox.send(draft, consentedSendingIdentity: address)
        isClosed = true
        model.composerClosed(id)
    }

    /// Saves on the device and to Fastmail's Drafts now, rather than after the pause in typing.
    public func saveNow() async {
        guard let model, mode == .editing, hasEdits else { return }
        if isDirty { await saveLocally() }
        await model.outbox.saveToServerNow(id.uuidString)
    }

    /// Closes the composer and keeps the draft (D11): saved on the device, and to Fastmail while it is a draft
    /// with changes the server doesn't have. A new message with nothing in it leaves nothing behind.
    public func close() async {
        guard let model, !isClosed else { return }
        autosave?.cancel()
        autosave = nil
        defer {
            isClosed = true
            model.composerClosed(id)
        }
        if notices.contains(.sentElsewhere), !keptAsNew {
            _ = await model.outbox.discard(id)
            return
        }
        guard hasEdits, mode == .editing else { return }
        if isEmptyNewMessage {
            _ = await model.outbox.discard(id)
            return
        }
        if isDirty { await saveLocally() }
        model.outbox.requestServerSave(id.uuidString)
    }

    /// Deletes the draft (D11, C3): from this device, and its copy on the server goes to Trash.
    public func discard() async -> Outbox.DiscardOutcome {
        guard let model else { return .discarded }
        autosave?.cancel()
        autosave = nil
        let outcome = await model.outbox.discard(id)
        if outcome == .discarded, !hasEdits, let origin {
            await model.outbox.discardServerDraft(origin.emailID)
        }
        isClosed = true
        model.composerClosed(id)
        return outcome
    }

    private var isEmptyNewMessage: Bool {
        kind == .new && original == nil && to.isEmpty && cc.isEmpty && bcc.isEmpty && attachments.isEmpty
            && subject.allSatisfy(\.isWhitespace) && body.characters.allSatisfy(\.isWhitespace)
    }

    private var isDirty: Bool {
        edits != savedEdits
    }

    /// The first edit allows saving; each edit restarts the pause after which it is saved (D8).
    private func edited() {
        guard !isClosed, mode == .editing, let model else { return }
        hasEdits = true
        edits += 1
        lastEditAt = model.clock.now
        if autosave == nil {
            autosave = Task { [weak self] in await self?.runAutosave() }
        }
    }

    /// Saves on the device a second after typing stops, and to the server five seconds after.
    private func runAutosave() async {
        while !isClosed, let model, let edit = lastEditAt, edit != autosavedEdit {
            do { try await model.clock.sleep(until: edit.addingTimeInterval(1)) } catch { break }
            guard lastEditAt == edit else { continue }
            if isDirty { await saveLocally() }
            do { try await model.clock.sleep(until: edit.addingTimeInterval(5)) } catch { break }
            guard lastEditAt == edit else { continue }
            autosavedEdit = edit
            model.outbox.requestServerSave(id.uuidString)
        }
        autosave = nil
    }

    @discardableResult
    func saveLocally() async -> Bool {
        guard let model, hasEdits else { return false }
        let edits = edits
        do {
            guard let revision = try await model.outbox.saveLocally(draft, origin: origin) else { return false }
            origin = nil
            savedRevision = revision
            savedEdits = max(savedEdits, edits)
            if case .savedToServer = saveStatus { saveStatus = .savedLocally } else if saveStatus != .savedLocally {
                saveStatus = .savedLocally
            }
            return true
        } catch {
            saveStatus = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: From the outbox

    func serverSaved(revision: Int64, at date: Date) {
        if revision >= (savedRevision ?? 0) { saveStatus = .savedToServer(date) }
    }

    func serverSaveFailed(_ message: String) {
        saveStatus = .failed(message)
    }

    /// The server save waits for a connection; the draft is safe on the device.
    func serverSaveDeferred() {
        if saveStatus != .unsaved { saveStatus = .savedLocally }
    }

    func receive(_ notice: ComposerNotice) {
        if !notices.contains(notice) { notices.append(notice) }
    }

    func adopt(messageID: String) {
        self.messageID = messageID
    }

    // MARK: Sender

    private func senderChanged() {
        guard let model else { return }
        let directory = model.senderDirectory
        if let from, directory.isMasked(from.email), from.name != nil {
            // Masked addresses go out without a name (D20); setting it runs this again.
            self.from = EmailAddress(email: from.email)
            return
        }
        applySender(directory)
        edited()
    }

    /// Signature, Reply-To, automatic Bcc and Message-ID for the current From.
    private func applySender(_ directory: SenderDirectory) {
        signature = includesSignature ? directory.signature(for: from?.email) : nil
        let settings = Self.settings(
            for: from, directory: directory, bcc: bcc, automaticBcc: automaticBcc, messageID: messageID)
        replyTo = settings.replyTo
        automaticBcc = settings.automaticBcc
        messageID = settings.messageID
        if settings.bcc != bcc { bcc = settings.bcc }
    }

    private struct SenderSettings {
        var replyTo: [EmailAddress]
        var bcc: [EmailAddress]
        var automaticBcc: [EmailAddress]
        var messageID: String
    }

    /// What sending from `from` brings along: its identity's Reply-To and automatic Bcc (the previous identity's
    /// taken out of `bcc`), none of them for a masked address (D20), and a Message-ID on its domain (D9).
    private static func settings(
        for from: EmailAddress?, directory: SenderDirectory, bcc: [EmailAddress], automaticBcc: [EmailAddress],
        messageID: String
    ) -> SenderSettings {
        let address = from?.email
        let identity = address.flatMap { directory.isMasked($0) ? nil : directory.identity(for: $0) }
        let added = identity?.bcc ?? []
        var bcc = bcc.filter { address in !automaticBcc.contains { $0.email.lowercased() == address.email.lowercased() } }
        for address in added where !bcc.contains(where: { $0.email.lowercased() == address.email.lowercased() }) {
            bcc.append(address)
        }
        var messageID = messageID
        if let domain = address.flatMap(AddressParser.domain(of:)),
           messageID.split(separator: "@").last.map({ $0.lowercased() }) != domain {
            messageID = MessageDraft.newMessageID(domain: domain)
        }
        return SenderSettings(replyTo: identity?.replyTo ?? [], bcc: bcc, automaticBcc: added, messageID: messageID)
    }
}

// MARK: - Opening composers

extension MailModel {
    /// Opens a composer: a new message, a reply or forward (§2.4), a server draft (§2.3), a restored one, or a
    /// `mailto:` link (C8). Nothing is written until the first edit.
    public func compose(_ request: ComposeRequest) async throws -> Composer {
        switch request {
        case .new(let to, let subject, let body, let from):
            let sender = from.map { senderDirectory.isMasked($0.email) ? EmailAddress(email: $0.email) : $0 }
                ?? sender(for: nil)?.address
            let draft = MessageDraft(
                kind: .new, from: sender, to: to, subject: subject, body: MailBodyNormalizer.normalize(body))
            return opened(Composer(model: self, draft: draft))

        case .reply(let emailID, let all):
            let loaded = try await original(emailID, needsBody: true)
            let choice = sender(for: loaded.email)
            let draft = ReplyBuilder.reply(
                to: loaded.email, all: all, from: choice?.address, isOwn: { self.isOwnAddress($0, in: loaded.email) })
            return opened(Composer(model: self, draft: draft, notices: loaded.notices, receivedAt: choice))

        case .forward(let emailID, let asAttachment):
            let loaded = try await original(emailID, needsBody: !asAttachment)
            if !asAttachment, !loaded.hasBody { throw SendProblem.inlineForwardIncomplete }
            let choice = sender(for: loaded.email)
            let draft = ReplyBuilder.forward(loaded.email, asAttachment: asAttachment, from: choice?.address)
            return opened(Composer(
                model: self, draft: draft, notices: asAttachment ? [] : loaded.notices, receivedAt: choice))

        case .draft(let emailID):
            if let row = try? await store.draft(serverEmailID: emailID), let id = UUID(uuidString: row.id),
               let composer = await composer(id: id) {
                return composer
            }
            let email = try await serverDraft(emailID)
            let domain = AddressParser.domain(of: username ?? account?.username ?? "") ?? "invalid"
            let parsed = DraftParser.parse(email, fallbackDomain: domain)
            let mode: Composer.Mode
            switch parsed.fidelity {
            case .exact: mode = .editing
            case .simplified(let features): mode = .preview(features)
            }
            let preview = mode == .editing ? nil : Self.previewContent(of: email)
            return opened(Composer(
                model: self, draft: parsed.draft, mode: mode,
                origin: Outbox.Origin(emailID: emailID, movesToTrash: mode != .editing), preview: preview))

        case .restore(let id):
            guard let composer = await composer(id: id) else { throw ComposeError.notFound }
            return composer

        case .mailto(let link, let sourceEmailID):
            var source: Email?
            if let sourceEmailID { source = try? await original(sourceEmailID, needsBody: false).email }
            let choice = sender(for: source)
            let to = AddressParser.parse(link.to.joined(separator: ", ") + ",").addresses
            let draft = MessageDraft(
                kind: .new, from: choice?.address, to: to, subject: link.subject ?? "",
                body: AttributedString(link.body ?? ""))
            return opened(Composer(model: self, draft: draft, receivedAt: source == nil ? nil : choice))
        }
    }

    /// The open composer with this id, or one restored from its draft row (window restoration, C27). A failed
    /// message opened to be edited becomes a draft again; queued and sending ones aren't opened.
    public func composer(id: UUID) async -> Composer? {
        if let open = openComposers[id] { return open }
        guard let row = try? await store.draft(id: id.uuidString), let draft = MailSend.draft(from: row) else {
            return nil
        }
        switch row.state {
        case .editing:
            break
        case .failed:
            _ = try? await store.updateOutbox(id: row.id) { row, record in
                guard row.state == .failed else { return }
                row.state = .editing
                row.queuedAt = nil
                record.resetSending()
            }
            await outbox.reload()
        case .queued, .submitting, .held:
            return nil
        }
        let lost = Set(await outbox.lostAttachments(of: draft).map(\.id))
        if let open = openComposers[id] { return open }
        let record = row.record
        let status: SaveStatus = row.hasUnsyncedChanges
            ? .savedLocally : .savedToServer(record.serverSavedAt ?? row.updatedAt)
        return opened(Composer(
            model: self, draft: draft, notices: [record.notice].compactMap { $0 }, restoredRevision: row.revision,
            saveStatus: status, lostAttachments: lost))
    }

    private func opened(_ composer: Composer) -> Composer {
        if let open = openComposers[composer.id] { return open }
        openComposers[composer.id] = composer
        return composer
    }

    func composerClosed(_ id: UUID) {
        openComposers[id] = nil
    }

    /// The original of a reply or forward with its body: as stored, or fetched again when the stored body is
    /// missing or cut short (C20). Offline, it may come without a body, and the notice says so.
    private func original(
        _ id: String, needsBody: Bool
    ) async throws -> (email: Email, hasBody: Bool, notices: [ComposerNotice]) {
        let listed = try? await store.emails(ids: [id]).first
        var stored: Email?
        if let threadID = listed?.threadId {
            stored = ((try? await store.emailsWithBodies(inThread: threadID)) ?? nil)?.first { $0.id == id }
        }
        if let stored, !needsBody || !Self.isTruncated(stored) {
            return (stored, true, [])
        }
        do {
            if let fetched = try await client.emails(ids: [id], maxBodyValueBytes: Self.originalBodyLimit).first {
                try? await store.upsert([fetched])
                return (fetched, true, Self.isTruncated(fetched) ? [.quoteShortened] : [])
            }
            if stored == nil, listed == nil { throw ComposeError.notFound }
        } catch let error as ComposeError {
            throw error
        } catch {
            if stored == nil, listed == nil { throw error }
        }
        if let stored { return (stored, true, Self.isTruncated(stored) ? [.quoteShortened] : []) }
        guard let listed else { throw ComposeError.notFound }
        return (listed, false, needsBody ? [.originalUnavailableOffline] : [])
    }

    /// A draft on the server with its body.
    private func serverDraft(_ id: String) async throws -> Email {
        do {
            if let email = try await client.emails(ids: [id], maxBodyValueBytes: Self.originalBodyLimit).first {
                return email
            }
            throw ComposeError.notFound
        } catch let error as ComposeError {
            throw error
        } catch {
            guard let threadID = try? await store.emails(ids: [id]).first?.threadId,
                  let email = ((try? await store.emailsWithBodies(inThread: threadID)) ?? nil)?.first(where: { $0.id == id })
            else { throw error }
            return email
        }
    }

    /// Bodies of originals are fetched up to 4 MB (C20).
    static let originalBodyLimit = 4_000_000

    static func isTruncated(_ email: Email) -> Bool {
        QuotedMessage(email).isTruncated
    }

    private static func previewContent(of email: Email) -> (html: String?, text: String?) {
        let quote = QuotedMessage(email)
        return (quote.html, quote.text)
    }
}
