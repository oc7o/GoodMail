import Foundation
import JMAPKit
import MailCompose
import MailStore
import Observation
import Synchronization

/// Why a message couldn't be sent and won't be retried without the user (§3.10).
public enum OutboxFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    case tokenLacksSubmission, readOnlyAccount
    /// A masked address Fastmail has no sending identity for (D21).
    case needsSendingIdentity(String)
    /// Fastmail refused to create a sending identity for the address.
    case identityRefused(String)
    case senderNotAllowed(String)
    case recipientsRejected([String]), tooManyRecipients(Int?), noRecipients
    case tooLarge(limit: Int?), attachmentUnavailable(String), attachmentDataLost(String)
    case refused(type: String, description: String?)

    public var errorDescription: String? {
        switch self {
        case .tokenLacksSubmission:
            "Your API token can't send mail. Replace it with one that has the Email submission scope."
        case .readOnlyAccount:
            "This Fastmail account is read-only."
        case .needsSendingIdentity(let address):
            "Fastmail only lets apps send from a masked address that is a sending address. Add \(address) under "
                + "Fastmail → Settings → My email addresses."
        case .identityRefused(let address):
            "Fastmail didn't allow sending from \(address)."
        case .senderNotAllowed(let address):
            "Fastmail doesn't let this account send from \(address)."
        case .recipientsRejected(let addresses):
            addresses.isEmpty
                ? "Fastmail rejected the recipients." : "Fastmail rejected: \(addresses.joined(separator: ", "))."
        case .tooManyRecipients(let limit):
            limit.map { "There are too many recipients; Fastmail allows \($0)." } ?? "There are too many recipients."
        case .noRecipients:
            "The message has no recipients."
        case .tooLarge(let limit):
            limit.map { "The message is too large; Fastmail allows \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))." }
                ?? "The message is too large for Fastmail."
        case .attachmentUnavailable(let name):
            "\(name) is no longer available."
        case .attachmentDataLost(let name):
            "Attach \(name) again: its data is no longer on this device."
        case .refused(let type, let description):
            description ?? "Fastmail refused the message (\(type))."
        }
    }
}

/// What the outbox needs from the account around it; `MailModel` provides it.
@MainActor
protocol OutboxHost: AnyObject {
    /// `nil` while the Drafts and Sent mailboxes aren't known.
    var outboxContext: SendContext? { get }
    var account: AccountSnapshot? { get }
    var isOnline: Bool { get }
    /// When the last successful sync of the stored mail started.
    var lastSyncStartedAt: Date? { get }
    func openComposer(_ id: UUID) -> Composer?
    /// Reads the identities again; `nil` when that fails.
    func outboxReloadIdentities() async -> SenderDirectory?
    func outboxCreatedIdentity(_ identity: Identity) async
    func outboxRefusedHold() async
    func outboxLostSubmissionScope() async
    /// Queues changes to emails in the triage outbox and sends them (they wait there while offline).
    func enqueueTriage(_ updates: [String: PatchObject]) async
    /// Something changed on the server that a refresh should bring in.
    func outboxChangedServer()
    func outboxTokenRejected()
}

/// Messages on their way out, and drafts written on this device (§2.2). It is independent of any view: App
/// Intents can call it directly.
///
/// Every message is a `draft` row in the store, whose state moves through editing → queued → submitting → held
/// and is then deleted once sent, or ends up failed. The store is the truth; this object runs the steps on each
/// draft's serial channel, keeps the deadlines on its clock, and shows what is happening.
@MainActor
@Observable
public final class Outbox {
    /// Fastmail holds every submission this long (`HOLDFOR`), so that Undo can cancel it (D12).
    nonisolated public static let holdSeconds = 15
    /// How long the Undo banner offers Undo, from the start of the submission.
    nonisolated public static let undoWindow: TimeInterval = 10
    /// How long Cancel is offered in the Outbox, from the start of the submission; Fastmail releases it no
    /// earlier than `holdSeconds` after receiving it.
    nonisolated public static let cancelDeadline: TimeInterval = 13

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var subject: String
        public var recipients: [EmailAddress]
        public var state: State
        public var updatedAt: Date
    }

    public enum State: Equatable, Sendable {
        /// Queued: not sent yet, and certainly not on its way (C2).
        case waiting(WaitReason)
        /// Its request is out, or what became of it is being checked.
        case sending
        /// Cancel or Delete was asked for while it was sending.
        case cancelling
        case held(undoUntil: Date, sendsAround: Date)
        case failed(OutboxFailure)
    }

    public enum WaitReason: Equatable, Sendable {
        case offline
        /// The fraction of its attachments' bytes uploaded, if known.
        case uploading(Double?)
        /// Fastmail was busy; the next try is due then.
        case retry(at: Date)
        /// Sent without a server hold: it goes out once the Undo window has passed on this device (D12).
        case localUndo(until: Date)
        /// Nothing is known about the account yet (first start without a connection).
        case unknownAccount
    }

    public struct UndoableSend: Equatable, Sendable {
        public let id: UUID
        public let subject: String
        public let undoUntil: Date
    }

    public struct DraftSummary: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var subject: String
        public var recipients: [EmailAddress]
        public var updatedAt: Date
    }

    public enum CancelOutcome: Equatable, Sendable {
        case backToDrafts
        /// It was being sent; the outcome follows once known.
        case requested
        case alreadySent
        case unreachable(sendsAround: Date)
    }

    public enum DiscardOutcome: Equatable, Sendable {
        case discarded
        case requested
        case alreadySent
        case unreachable(sendsAround: Date)
    }

    /// One-off news about a message, each carrying its subject.
    public enum Notice: Equatable, Sendable, Identifiable {
        case sentElsewhere(String)
        case canceledElsewhere(String)
        case alreadySent(String)
        case canceled(String)

        public var id: String {
            switch self {
            case .sentElsewhere(let subject): "sentElsewhere:" + subject
            case .canceledElsewhere(let subject): "canceledElsewhere:" + subject
            case .alreadySent(let subject): "alreadySent:" + subject
            case .canceled(let subject): "canceled:" + subject
            }
        }
    }

    /// Queued, sending, held and failed messages, oldest first.
    public private(set) var items: [Item] = []
    /// Drafts edited here that Fastmail doesn't have yet.
    public private(set) var unsyncedDrafts: [DraftSummary] = []
    /// The message whose Undo is offered right now.
    public private(set) var undoable: UndoableSend?
    public private(set) var notices: [Notice] = []
    /// Upload progress of outgoing attachments, by attachment id.
    private(set) var uploadStates: [UUID: UploadState] = [:]

    @ObservationIgnored weak var host: (any OutboxHost)?
    @ObservationIgnored let store: MailStore
    @ObservationIgnored let client: JMAPClient
    @ObservationIgnored let clock: any OutboxClock
    @ObservationIgnored let steps: MailSend
    @ObservationIgnored let activity: any BackgroundActivity
    /// How sending from masked addresses works; tests turn identity creation on.
    @ObservationIgnored var maskedSending = MaskedSending()
    @ObservationIgnored private let channels = OutboxChannels()
    @ObservationIgnored private let flushes = SingleFlight()
    @ObservationIgnored private var rows: [StoredDraft] = []
    @ObservationIgnored private var headers: [String: (revision: Int64, header: DraftHeader)] = [:]
    @ObservationIgnored private var uploadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var wakeUp: Task<Void, Never>?
    /// Drafts whose open composer asked for a server save that hasn't happened yet.
    @ObservationIgnored private var serverSaveRequests: Set<String> = []
    /// Drafts whose server save waits for their uploads.
    @ObservationIgnored private(set) var draftsWaitingForUploads: Set<String> = []
    @ObservationIgnored private var uploadWaiters: [String: [FirstOf]] = [:]
    @ObservationIgnored private var isRunning = false

    init(client: JMAPClient, store: MailStore, clock: any OutboxClock, activity: any BackgroundActivity) {
        self.client = client
        self.store = store
        self.clock = clock
        self.activity = activity
        steps = MailSend(client: client, store: store, clock: clock, assembly: MessageAssembly())
    }

    // MARK: Running

    func start() async {
        isRunning = true
        await reload()
        scheduleWakeUp()
    }

    /// Stops timers, flushes and uploads. Work cut short is picked up by the persisted states on the next start.
    func stop() {
        isRunning = false
        wakeUp?.cancel()
        wakeUp = nil
        flushes.cancel()
        channels.cancelAll()
        for task in uploadTasks.values { task.cancel() }
        uploadTasks = [:]
        for waiter in uploadWaiters.values.joined() { waiter.resume() }
        uploadWaiters = [:]
    }

    /// Has a flush run soon; one under way goes once more.
    public func requestFlush() {
        guard isRunning else { return }
        flushes.start { await self.flushOnce() }
    }

    /// One full pass over the outbox. Returns whether work remains.
    public func flushNow() async -> Bool {
        if isRunning { await flushes.start { await self.flushOnce() }.value }
        return hasPendingWork
    }

    /// The network is back: messages that waited for a connection go out now rather than after their backoff
    /// (§2.8).
    func connectionReturned() {
        guard isRunning else { return }
        Task {
            await retryWaitingForConnection()
            requestFlush()
        }
    }

    /// Makes messages that waited for a connection due right away.
    func retryWaitingForConnection() async {
        let waiting = ((try? await store.drafts(in: [.queued])) ?? []).filter { $0.record.wait == .connection }
        for row in waiting {
            _ = try? await store.updateOutbox(id: row.id) { row, record in
                guard row.state == .queued, record.wait == .connection, !record.localDelay else { return }
                record.notBefore = nil
                record.wait = nil
            }
        }
    }

    /// Waits for the flush under way, if any, without asking for another pass.
    func waitForCurrentFlush() async {
        await flushes.current?.value
    }

    /// Waits until nothing runs on any draft's channel, for tests and before the app is suspended.
    func waitUntilIdle() async {
        await channels.idle()
        while let upload = uploadTasks.values.first { await upload.value }
        await channels.idle()
    }

    public var hasPendingWork: Bool {
        !uploadTasks.isEmpty || rows.contains { row in
            switch row.state {
            case .queued, .submitting, .held: true
            case .editing: row.hasUnsyncedChanges || !row.record.pendingDestroy.isEmpty
            case .failed: !row.record.pendingDestroy.isEmpty
            }
        }
    }

    /// The fraction of the draft's attachment bytes uploaded while uploads for it are pending, else `nil`.
    public func uploadProgress(for id: UUID) -> Double? {
        let key = id.uuidString
        guard uploadTasks[key] != nil, let header = headers[key]?.header else { return nil }
        let local = header.attachments.filter { $0.source == .local }
        let total = local.reduce(0) { $0 + max($1.size, 1) }
        guard total > 0 else { return nil }
        let done = local.filter { uploadStates[$0.id] == .uploaded }.reduce(0) { $0 + max($1.size, 1) }
        return Double(done) / Double(total)
    }

    public func dismiss(_ notice: Notice) {
        if let index = notices.firstIndex(of: notice) { notices.remove(at: index) }
    }

    // MARK: Saving

    /// Saves the draft on this device and, with `toServer`, then to Fastmail's Drafts.
    public func save(_ draft: MessageDraft, toServer: Bool) async throws {
        try await saveLocally(draft)
        if toServer { await saveToServerNow(draft.id.uuidString) }
    }

    /// Where a draft opened from the server came from.
    struct Origin: Sendable {
        var emailID: String
        /// GoodMail can't edit it without loss: it isn't replaced but moved to Trash after the first save (D32).
        var movesToTrash: Bool
    }

    /// Writes the draft's content as a new revision; a failed message being edited becomes a draft again.
    /// Returns the revision, or `nil` when the message is on its way and its content can't change.
    @discardableResult
    func saveLocally(_ draft: MessageDraft, origin: Origin? = nil) async throws -> Int64? {
        let id = draft.id.uuidString
        let content = try MailSend.encode(draft)
        let existing = try await store.draft(id: id)
        if let existing, existing.state != .editing, existing.state != .failed { return nil }
        let revision = try await store.saveDraftContent(
            id: id, content: content, messageID: draft.messageID, state: existing?.state == .failed ? .editing : nil)
        if existing == nil {
            let now = clock.now
            try await store.updateOutbox(id: id) { row, record in
                record.createdAt = now
                guard let origin else { return }
                if origin.movesToTrash {
                    record.trashOnFirstSave = origin.emailID
                } else {
                    row.serverEmailID = origin.emailID
                    row.serverRevision = 0
                    record.serverMessageID = draft.messageID
                    record.serverSavedAt = now
                }
            }
        } else if existing?.state == .failed {
            try await store.updateOutbox(id: id) { _, record in record.resetSending() }
        }
        await reload()
        return revision
    }

    /// Asks for a server save of the draft on its channel and returns at once (D8).
    func requestServerSave(_ id: String) {
        serverSaveRequests.insert(id)
        guard isRunning else { return }
        let save = channels.enqueue(id) { [self] in await serverSaveStep(id) }
        Task { _ = await save.result; await self.reload() }
    }

    /// Saves the draft to the server on its channel, if it is still a draft with changes Fastmail doesn't have.
    func saveToServerNow(_ id: String) async {
        serverSaveRequests.insert(id)
        guard isRunning else { return }
        try? await channels.run(id) { [self] in await serverSaveStep(id) }
        await reload()
    }

    private func serverSaveStep(_ id: String) async {
        guard let host, host.isOnline, let context = host.outboxContext else {
            host?.openComposer(UUID(uuidString: id) ?? UUID())?.serverSaveDeferred()
            return
        }
        await saveToServer(id, context: context)
    }

    /// The server save (§2.3): waits up to a minute for the draft's uploads, saves with what is uploaded, and
    /// then sorts out conflicts with other devices.
    private func saveToServer(_ id: String, context: SendContext) async {
        serverSaveRequests.remove(id)
        guard let row = try? await store.draft(id: id) else { return }
        // A copy moved to Trash elsewhere must not be destroyed by replacing it.
        if await checkServerCopy(row, context: context) { return }
        // Sent from another device: nothing is saved under its Message-ID until the user keeps it as new.
        if row.record.notice == .sentElsewhere { return }
        startUploads(id)
        await waitForUploads(id, timeout: 60)
        let blobIDs = await uploadedBlobIDs(id)
        let composer = host?.openComposer(UUID(uuidString: id) ?? UUID())
        switch await steps.saveToServer(id, context: context, blobIDs: blobIDs) {
        case .notNeeded:
            break
        case .saved(_, let revision, let leftOut, let needsLookup, let previousWasMissing):
            composer?.serverSaved(revision: revision, at: clock.now)
            if leftOut { await tell(id, .attachmentsNotOnServerYet) }
            if let trashed = try? await store.draft(id: id)?.record.trashOnFirstSave {
                await moveToTrash([trashed], context: context)
                _ = try? await store.updateOutbox(id: id) { _, record in record.trashOnFirstSave = nil }
            }
            if needsLookup {
                let trigger = MailSend.LookupTrigger.save(previousWasMissing: previousWasMissing)
                if let conflict = try? await steps.lookUpConflicts(id, trigger: trigger, mailboxes: context.mailboxes) {
                    await resolve(conflict, id: id, trigger: trigger, context: context)
                }
            }
            if let row = try? await store.draft(id: id), !row.record.pendingDestroy.isEmpty {
                _ = try? await steps.cleanup(id)
            }
            host?.outboxChangedServer()
        case .refused(let message):
            composer?.serverSaveFailed(message)
        case .unreachable(let error):
            if error == .unauthorized { host?.outboxTokenRejected() }
            if SendError.isNoConnection(error) || error.isTemporary {
                composer?.serverSaveDeferred()
            } else {
                composer?.serverSaveFailed(error.localizedDescription)
            }
        }
    }

    // MARK: Sending

    /// Queues the draft for sending, with the content and the queued state written in one transaction, so that
    /// a save arriving afterwards sees it is no draft any more (C5).
    ///
    /// Throws a `SendProblem` when it can't be sent as it is. `consentedSendingIdentity` is the exact address
    /// the user agreed to create a sending identity for, while that is allowed (D21, C24).
    public func send(_ draft: MessageDraft, consentedSendingIdentity: String? = nil) async throws {
        var draft = draft
        let id = draft.id.uuidString
        let lost = await lostAttachments(of: draft).map(\.name)
        let directory = host?.outboxContext?.directory ?? SenderDirectory(login: host?.account?.username)
        let problems = SendCheck.problems(
            for: draft, availability: host?.account?.sendAvailability ?? .unknown, account: host?.account,
            directory: directory, policy: maskedSending, lostAttachments: lost)
        if let problem = problems.first { throw problem }
        // Consent counts only for the exact address it was given for (C24).
        if let from = draft.from?.email, !directory.identities.isEmpty,
           directory.needsSendingIdentity(for: from, policy: maskedSending),
           consentedSendingIdentity?.lowercased() != from.lowercased() {
            throw SendProblem.needsSendingIdentity(from)
        }
        // D9: the Message-ID is on From's domain, whatever happened to From since it was made.
        if let domain = draft.from.flatMap({ AddressParser.domain(of: $0.email) }),
           draft.messageIDDomain?.lowercased() != domain {
            draft.messageID = MessageDraft.newMessageID(domain: domain)
        }
        let content = try MailSend.encode(draft)
        if try await store.draft(id: id) == nil {
            try await saveLocally(draft)
        }
        let now = clock.now
        let waitsLocally = !(host?.account?.holdsOnServer ?? true)
        let consent = consentedSendingIdentity
        let messageID = draft.messageID
        let row = try await store.updateOutbox(id: id) { row, record in
            guard row.state == .editing || row.state == .failed else { return }
            if row.content != content {
                row.content = content
                row.revision += 1
            }
            row.messageID = messageID
            row.state = .queued
            row.queuedAt = now
            record.resetSending()
            record.consentedSendingIdentity = consent
            record.notice = nil
            if waitsLocally {
                record.localDelay = true
                record.notBefore = now.addingTimeInterval(Self.undoWindow)
            }
        }
        await steps.assembly.forget(draft.id)
        await reload()
        if row?.state == .queued { requestFlush() }
    }

    /// Takes a message out of the outbox (Undo, Cancel), by state (§2.2).
    public func cancel(_ id: UUID) async -> CancelOutcome {
        let key = id.uuidString
        guard let row = try? await store.draft(id: key) else { return .alreadySent }
        switch row.state {
        case .editing:
            return .backToDrafts
        case .queued, .failed:
            let changed = try? await store.updateOutbox(id: key) { row, record in
                guard row.state == .queued || row.state == .failed else { return }
                row.state = .editing
                row.queuedAt = nil
                record.resetSending()
            }
            await reload()
            if changed?.state == .editing { return .backToDrafts }
            // It went out meanwhile.
            return changed == nil ? .alreadySent : await cancel(id)
        case .submitting:
            _ = try? await store.updateOutbox(id: key) { row, record in
                if row.state == .submitting { record.cancelRequested = true }
            }
            await reload()
            requestFlush()
            return .requested
        case .held:
            let outcome = try? await channels.run(key) { [self] in await cancelHeld(key, discarding: false) }
            await reload()
            return outcome ?? .alreadySent
        }
    }

    /// Deletes a draft or a message, by state (§2.2, C3): never anything that may still go out without it.
    public func discard(_ id: UUID) async -> DiscardOutcome {
        let key = id.uuidString
        await steps.assembly.forget(id)
        guard let row = try? await store.draft(id: key) else { return .discarded }
        switch row.state {
        case .editing, .queued, .failed:
            let claimed = try? await store.updateOutbox(id: key) { row, record in
                guard row.state == .editing || row.state == .queued || row.state == .failed else { return }
                row.state = .editing
                record.discardRequested = true
            }
            guard claimed?.record.discardRequested == true, claimed?.state == .editing else {
                return claimed == nil ? .discarded : await discard(id)
            }
            await discardLocally(key)
            await reload()
            return .discarded
        case .submitting:
            _ = try? await store.updateOutbox(id: key) { row, record in
                guard row.state == .submitting else { return }
                record.cancelRequested = true
                record.discardRequested = true
            }
            await reload()
            requestFlush()
            return .requested
        case .held:
            let outcome = try? await channels.run(key) { [self] () -> DiscardOutcome in
                switch await cancelHeld(key, discarding: true) {
                case .backToDrafts:
                    await discardLocally(key)
                    return .discarded
                case .requested: return .requested
                case .alreadySent: return .alreadySent
                case .unreachable(let time): return .unreachable(sendsAround: time)
                }
            }
            await reload()
            return outcome ?? .alreadySent
        }
    }

    /// Queues a failed message again.
    public func retry(_ id: UUID) {
        let key = id.uuidString
        Task {
            let now = clock.now
            _ = try? await store.updateOutbox(id: key) { row, record in
                guard row.state == .failed else { return }
                row.state = .queued
                row.queuedAt = now
                record.failure = nil
                record.notBefore = nil
                record.attempts = 0
                record.wait = nil
            }
            await reload()
            requestFlush()
        }
    }

    /// Moves a draft that exists only on the server to Trash, as when one opened read-only is deleted (D11).
    func discardServerDraft(_ emailID: String) async {
        guard let context = host?.outboxContext else { return }
        await moveToTrash([emailID], context: context)
    }

    // MARK: The flush

    private func flushOnce() async {
        guard isRunning, let host else { return }
        let end = activity.begin("Sending mail")
        defer { end() }
        await reload()
        let order = rows.sorted {
            ($0.queuedAt ?? .distantFuture, $0.updatedAt, $0.id) < ($1.queuedAt ?? .distantFuture, $1.updatedAt, $1.id)
        }
        for row in order {
            guard isRunning else { break }
            let online = host.isOnline
            try? await channels.run(row.id) { [self] in await step(row.id, online: online) }
        }
        await reload()
        scheduleWakeUp()
    }

    /// One draft's turn in a flush: whatever its state calls for, if it is due.
    private func step(_ id: String, online: Bool) async {
        guard isRunning, let row = try? await store.draft(id: id) else { return }
        let record = row.record
        let now = clock.now
        if row.state == .editing, record.discardRequested {
            // A discard that was cut short.
            return await discardLocally(id)
        }
        if row.state == .queued {
            switch host?.account?.sendAvailability {
            case .tokenLacksSubmission?: return await fail(id, .tokenLacksSubmission)
            case .readOnlyAccount?: return await fail(id, .readOnlyAccount)
            case nil: return
            case .available?, .unknown?: break
            }
        }
        guard online, let context = host?.outboxContext else { return }
        if !record.pendingDestroy.isEmpty {
            _ = try? await steps.cleanup(id)
        }
        await stepByState(row, context: context, now: now)
        // Strays the step itself left, such as the email of a refused submission (D33).
        if let left = try? await store.draft(id: id)?.record.pendingDestroy, !left.isEmpty {
            _ = try? await steps.cleanup(id)
        }
    }

    private func stepByState(_ row: StoredDraft, context: SendContext, now: Date) async {
        let id = row.id
        let record = row.record
        switch row.state {
        case .editing, .failed:
            if await checkServerCopy(row, context: context) { return }
            let isOpen = host?.openComposer(UUID(uuidString: id) ?? UUID()) != nil
            if row.hasUnsyncedChanges, !isOpen || serverSaveRequests.contains(id) {
                await saveToServer(id, context: context)
            }
        case .queued:
            if (record.notBefore ?? .distantPast) <= now { await sendQueued(id, context: context) }
        case .submitting:
            if (record.verifyAt ?? .distantPast) <= now { await verify(id, context: context) }
        case .held:
            if let submission = record.submission, Self.checkDue(submission) <= now {
                await checkRelease(id, context: context)
            }
        }
    }

    private static func checkDue(_ submission: OutboxRecord.Submission) -> Date {
        submission.nextCheckAt ?? submission.heldAt.addingTimeInterval(TimeInterval(holdSeconds) + 2)
    }

    /// The send protocol for a queued message (§2.2): validate, find the sending identity, upload, check that
    /// no other device sent it, then submit.
    private func sendQueued(_ id: String, context: SendContext) async {
        guard let row = try? await store.draft(id: id), row.state == .queued, var draft = MailSend.draft(from: row) else {
            return
        }
        var record = row.record
        if let failure = SendCheck.queuedFailure(for: draft) { return await fail(id, failure) }
        guard let identity = await sendingIdentity(id, draft: draft, record: record, context: context) else { return }
        guard var blobIDs = await uploadAll(id, draft: draft) else { return }

        let account = host?.account ?? context.account
        if !record.localDelay, account?.holdsOnServer == false {
            // Fastmail can't hold it: the Undo window passes on this device first (D12).
            let until = clock.now.addingTimeInterval(Self.undoWindow)
            _ = try? await store.updateOutbox(id: id) { _, record in
                record.localDelay = true
                record.notBefore = until
            }
            return
        }

        do {
            switch try await steps.preCheck(row, mailboxes: context.mailboxes) {
            case .clear:
                break
            case .sentElsewhere:
                // Its draft here is obsolete too; nothing is sent (C29).
                _ = try? await store.updateOutbox(id: id) { row, record in
                    record.destroyLater([row.serverEmailID].compactMap { $0 })
                    row.serverEmailID = nil
                }
                return await finalize(id, context: context, notice: .sentElsewhere(draft.subject))
            case .otherVersion:
                draft = await fork(id, draft: draft, droppingServerCopy: false) ?? draft
                record = (try? await store.draft(id: id))?.record ?? record
            }
        } catch {
            return await notSent(id, SendError.jmap(error))
        }

        let holdFor = record.localDelay ? nil : Self.holdSeconds
        for attempt in 0..<2 {
            let outcome: MailSend.SubmitOutcome?
            do {
                outcome = try await steps.submit(
                    id, draft: draft, identity: identity, blobIDs: blobIDs, holdFor: holdFor, context: context)
            } catch {
                return await fail(id, .refused(type: "invalidMessage", description: error.localizedDescription))
            }
            switch outcome {
            case nil:
                return
            case .held(let submission)?:
                return await submitted(id, submission: submission, context: context)
            case .released?:
                return await finalize(id, context: context, notice: nil)
            case .holdRefused(let submittedAt)?:
                // C23: remembered for the account; this message waits out the rest of its Undo window here.
                await host?.outboxRefusedHold()
                let until = submittedAt.addingTimeInterval(Self.undoWindow)
                _ = try? await store.updateOutbox(id: id) { _, record in
                    record.localDelay = true
                    record.notBefore = until
                }
                return requestFlushSoon()
            case .failed(let failure)?:
                return await fail(id, failure)
            case .blobsNotFound(let missing)? where attempt == 0:
                for attachment in draft.attachments {
                    switch attachment.source {
                    case .server(let blobId) where missing.contains(blobId):
                        return await fail(id, .attachmentUnavailable(attachment.name))
                    case .local where blobIDs[attachment.id].map(missing.contains) == true:
                        try? await store.markOutgoingAttachmentExpired(id: attachment.id.uuidString)
                    default:
                        break
                    }
                }
                guard let uploaded = await uploadAll(id, draft: draft) else { return }
                blobIDs = uploaded
            case .blobsNotFound?:
                return await fail(id, .refused(type: SetError.blobNotFound, description: nil))
            case .busy?:
                return await backOff(id, .busy)
            case .notSent(let error)?:
                return await notSent(id, error)
            case .unknown?:
                // Verified by the next flush, never by repeating the request (D14).
                let at = clock.now
                _ = try? await store.updateOutbox(id: id) { _, record in record.verifyAt = at }
                return
            }
        }
    }

    /// A submission Fastmail holds: destroy the earlier versions at once (D33), and honour a cancel asked for
    /// while the request was out.
    private func submitted(_ id: String, submission: OutboxRecord.Submission, context: SendContext) async {
        _ = try? await steps.cleanup(id)
        host?.outboxChangedServer()
        guard let record = try? await store.draft(id: id)?.record, record.cancelRequested else { return }
        await resolveRequestedCancel(id, record: record, context: context)
    }

    /// A cancel or discard asked for while the message was sending, now that it is known to be held.
    private func resolveRequestedCancel(_ id: String, record: OutboxRecord, context: SendContext) async {
        let subject = await subject(of: id)
        switch await cancelHeld(id, discarding: record.discardRequested) {
        case .backToDrafts:
            if record.discardRequested { await discardLocally(id) }
            notices.append(.canceled(subject))
        case .alreadySent:
            notices.append(.alreadySent(subject))
        case .requested, .unreachable:
            break
        }
    }

    /// The identity to submit with, creating one for a masked address when that is allowed and the user agreed
    /// for exactly this address (D21). `nil` when the message can't go now; its row says why.
    private func sendingIdentity(
        _ id: String, draft: MessageDraft, record: OutboxRecord, context: SendContext
    ) async -> Identity? {
        guard let from = draft.from?.email else {
            await fail(id, .refused(type: "noSender", description: nil))
            return nil
        }
        var directory = context.directory
        if directory.identities.isEmpty, let reloaded = await host?.outboxReloadIdentities() {
            directory = reloaded
        }
        guard !directory.identities.isEmpty else {
            // Not known yet, which says nothing about this address: try again later.
            await backOff(id, host?.isOnline == false ? .connection : .busy)
            return nil
        }
        switch directory.sendingIdentity(for: from, consent: record.consentedSendingIdentity, policy: maskedSending) {
        case .identity(let identity):
            return identity
        case .notAllowed(let address):
            await fail(id, .senderNotAllowed(address))
        case .missingForMask(let address):
            await fail(id, .needsSendingIdentity(address))
        case .create(let address):
            // An identity may exist by now: made elsewhere, or by an attempt whose answer was lost.
            guard let reloaded = await host?.outboxReloadIdentities() else {
                await backOff(id, .connection)
                return nil
            }
            if let identity = reloaded.identity(for: address) { return identity }
            do {
                let identity = try await client.createIdentity(Identity.Create(name: "", email: address))
                await host?.outboxCreatedIdentity(identity)
                return identity
            } catch is SetError {
                await fail(id, .identityRefused(address))
            } catch {
                await notSent(id, SendError.jmap(error))
            }
        }
        return nil
    }

    /// Verifies a message whose submission's answer was lost (D14), then applies a cancel asked for meanwhile.
    private func verify(_ id: String, context: SendContext) async {
        let outcome: MailSend.Verification?
        do {
            outcome = try await steps.verify(id, mailboxes: context.mailboxes)
        } catch {
            let at = clock.now.addingTimeInterval(30)
            _ = try? await store.updateOutbox(id: id) { _, record in record.verifyAt = at }
            return
        }
        guard let outcome, let row = try? await store.draft(id: id) else { return }
        let record = row.record
        let subject = MailSend.draft(from: row)?.subject ?? ""
        switch outcome {
        case .notSent:
            if record.discardRequested {
                await discardLocally(id)
                notices.append(.canceled(subject))
            } else if record.cancelRequested {
                _ = try? await store.updateOutbox(id: id) { row, record in
                    guard row.state == .queued else { return }
                    row.state = .editing
                    row.queuedAt = nil
                    record.resetSending()
                }
                notices.append(.canceled(subject))
            } else {
                requestFlushSoon()
            }
        case .held(let submission):
            await submitted(id, submission: submission, context: context)
        case .released:
            await finalize(id, context: context, notice: record.cancelRequested ? .alreadySent(subject) : nil)
        }
    }

    /// Whether a held message went out (C15): pending ones are checked again in 5 s, after ten checks every
    /// minute; a cancel nobody here asked for means it was cancelled on another device.
    private func checkRelease(_ id: String, context: SendContext) async {
        guard let row = try? await store.draft(id: id), row.state == .held, let submission = row.record.submission
        else { return }
        let record = row.record
        let release: MailSend.Release
        do {
            release = try await steps.checkRelease(submission, mailboxes: context.mailboxes)
        } catch {
            let at = clock.now.addingTimeInterval(SendError.isNoConnection(SendError.jmap(error)) ? 60 : 5)
            _ = try? await store.updateOutbox(id: id) { _, record in record.submission?.nextCheckAt = at }
            return
        }
        let subject = MailSend.draft(from: row)?.subject ?? ""
        switch release {
        case .pending:
            let now = clock.now
            _ = try? await store.updateOutbox(id: id) { _, record in
                guard var submission = record.submission else { return }
                submission.checks += 1
                submission.nextCheckAt = now.addingTimeInterval(submission.checks < 10 ? 5 : 60)
                record.submission = submission
            }
        case .released:
            await finalize(id, context: context, notice: record.cancelRequested ? .alreadySent(subject) : nil)
        case .canceled:
            await backToDrafts(id, emailID: submission.emailID)
            if record.cancelRequested {
                // A cancel of ours whose answer was lost: it did go through.
                if record.discardRequested { await discardLocally(id) }
                notices.append(.canceled(subject))
            } else {
                await tell(id, nil)
                notices.append(.canceledElsewhere(subject))
            }
            host?.outboxChangedServer()
        }
    }

    /// Cancels a held submission on the draft's channel (Undo, Cancel; C3, C15).
    private func cancelHeld(_ id: String, discarding: Bool) async -> CancelOutcome {
        guard let row = try? await store.draft(id: id) else { return .alreadySent }
        guard row.state == .held, let submission = row.record.submission else {
            switch row.state {
            case .editing: return .backToDrafts
            case .submitting, .queued, .failed, .held: return .requested
            }
        }
        let sendsAround = submission.submittedAt.addingTimeInterval(TimeInterval(Self.holdSeconds))
        guard clock.now < submission.submittedAt.addingTimeInterval(Self.cancelDeadline) else { return .alreadySent }
        guard host?.isOnline == true, let context = host?.outboxContext else {
            return .unreachable(sendsAround: sendsAround)
        }
        let start = clock.now
        _ = try? await store.updateOutbox(id: id) { _, record in record.begin(.cancel, at: start) }
        do {
            switch try await client.cancelSubmission(submission.id, mailboxes: context.mailboxes.roles) {
            case .canceled:
                await backToDrafts(id, emailID: submission.emailID)
                host?.outboxChangedServer()
                return .backToDrafts
            case .alreadySent:
                await finalize(id, context: context, notice: nil)
                return .alreadySent
            case .failed:
                _ = try? await store.updateOutbox(id: id) { _, record in record.lastAttempt = nil }
                return .unreachable(sendsAround: sendsAround)
            }
        } catch {
            // Possibly cancelled after all: the intent stays, and the release check completes it (C3).
            let mayHaveRun = SendError.jmap(error).mayHaveReachedServer
            _ = try? await store.updateOutbox(id: id) { _, record in
                record.lastAttempt = nil
                if mayHaveRun {
                    record.cancelRequested = true
                    if discarding { record.discardRequested = true }
                }
            }
            return .unreachable(sendsAround: sendsAround)
        }
    }

    /// A message the server holds no more, whose email is back in Drafts: it is a draft again, with that email
    /// as its server copy.
    private func backToDrafts(_ id: String, emailID: String) async {
        let now = clock.now
        _ = try? await store.updateOutbox(id: id) { row, record in
            row.state = .editing
            row.queuedAt = nil
            row.serverEmailID = emailID
            row.serverRevision = row.revision
            record.serverMessageID = row.messageID
            record.serverSavedAt = now
            record.resetSending()
            record.lastAttempt = nil
        }
    }

    /// The message went out: the original gets `$answered` or `$forwarded` (D17), leftovers are destroyed,
    /// and the row with its attachments goes (§2.2 Finalize).
    private func finalize(_ id: String, context: SendContext, notice: Notice?) async {
        guard let row = try? await store.draft(id: id) else { return }
        let draft = MailSend.draft(from: row)
        if !row.record.pendingDestroy.isEmpty, (try? await steps.cleanup(id)) != true {
            let left = (try? await store.draft(id: id))?.record.pendingDestroy ?? row.record.pendingDestroy
            await moveToTrash(left, context: context)
        }
        if let trashed = row.record.trashOnFirstSave { await moveToTrash([trashed], context: context) }
        if let draft, let original = draft.original?.emailID {
            let keyword: Email.Keyword? = switch draft.kind {
            case .reply, .replyAll: .answered
            case .forward, .forwardAsAttachment: .forwarded
            case .new: nil
            }
            if let keyword { await host?.enqueueTriage([original: .setKeyword(keyword, true)]) }
        }
        try? await store.deleteDraft(id: id)
        if let draft {
            await steps.assembly.forget(draft.id)
            for attachment in draft.attachments { uploadStates[attachment.id] = nil }
        }
        if let notice { notices.append(notice) }
        host?.outboxChangedServer()
    }

    /// Deletes the row with its attachments, and moves its server copies to Trash through the triage outbox,
    /// which works offline and keeps them recoverable (D11).
    private func discardLocally(_ id: String) async {
        guard let row = try? await store.draft(id: id) else { return }
        let record = row.record
        var copies: [String] = []
        for copy in [row.serverEmailID, record.trashOnFirstSave].compactMap({ $0 }) + record.pendingDestroy
        where !copies.contains(copy) {
            copies.append(copy)
        }
        try? await store.deleteDraft(id: id)
        if let draft = MailSend.draft(from: row) {
            await steps.assembly.forget(draft.id)
            for attachment in draft.attachments { uploadStates[attachment.id] = nil }
        }
        if let context = host?.outboxContext {
            await moveToTrash(copies, context: context)
        } else if !copies.isEmpty {
            _ = try? await client.destroyEmails(copies)
        }
        host?.outboxChangedServer()
    }

    private func moveToTrash(_ ids: [String], context: SendContext) async {
        guard !ids.isEmpty else { return }
        guard let trash = context.mailboxes.trash else {
            _ = try? await client.destroyEmails(ids)
            return
        }
        await host?.enqueueTriage(Dictionary(uniqueKeysWithValues: ids.map { ($0, PatchObject.moveExclusively(to: trash)) }))
    }

    // MARK: Conflicts (§2.3)

    /// The server-copy check: a draft whose copy the synced store no longer has in Drafts, after a sync that
    /// started once the copy existed. Returns whether it dealt with the row.
    private func checkServerCopy(_ row: StoredDraft, context: SendContext) async -> Bool {
        let record = row.record
        guard let copyID = row.serverEmailID, let savedAt = record.serverSavedAt,
              let synced = host?.lastSyncStartedAt, synced > savedAt
        else { return false }
        if let stored = try? await store.emails(ids: [copyID]).first,
           stored.mailboxIds?[context.mailboxes.drafts] == true {
            return false
        }
        let conflict: MailSend.Conflict
        do {
            conflict = try await steps.lookUpConflicts(row.id, trigger: .serverCopyCheck, mailboxes: context.mailboxes)
        } catch {
            return true
        }
        if conflict == .none {
            // It is there; the store just hasn't seen it. Storing it spares the next sync's check this lookup.
            if let email = try? await client.emails(ids: [copyID], properties: Email.Properties.listing) {
                try? await store.upsert(email)
            }
            let now = clock.now
            _ = try? await store.updateOutbox(id: row.id) { _, record in record.serverSavedAt = now }
            return false
        }
        await resolve(conflict, id: row.id, trigger: .serverCopyCheck, context: context)
        return true
    }

    /// Applies the outcome of a conflict lookup (§2.3 table).
    private func resolve(
        _ conflict: MailSend.Conflict, id: String, trigger: MailSend.LookupTrigger, context: SendContext
    ) async {
        let composer = host?.openComposer(UUID(uuidString: id) ?? UUID())
        switch conflict {
        case .none:
            break
        case .sentElsewhere:
            _ = try? await store.updateOutbox(id: id) { row, record in
                record.destroyLater([row.serverEmailID].compactMap { $0 })
                row.serverEmailID = nil
                row.serverRevision = nil
                record.notice = .sentElsewhere
            }
            _ = try? await steps.cleanup(id)
            if let composer {
                composer.receive(.sentElsewhere)
            } else {
                let subject = await subject(of: id)
                if let left = try? await store.draft(id: id)?.record.pendingDestroy, !left.isEmpty {
                    await moveToTrash(left, context: context)
                }
                try? await store.deleteDraft(id: id)
                notices.append(.sentElsewhere(subject))
            }
        case .editedElsewhere:
            guard let row = try? await store.draft(id: id), let draft = MailSend.draft(from: row) else { return }
            _ = await fork(id, draft: draft, droppingServerCopy: trigger == .serverCopyCheck)
            await saveToServer(id, context: context)
        case .discardedElsewhere:
            guard let row = try? await store.draft(id: id) else { return }
            if trigger == .serverCopyCheck {
                if !row.hasUnsyncedChanges, composer == nil {
                    try? await store.deleteDraft(id: id)
                    return
                }
                // Kept, and saved again as a new copy; the one in Trash stays there.
                _ = try? await store.updateOutbox(id: id) { row, _ in
                    row.serverEmailID = nil
                    row.serverRevision = nil
                }
                await tell(id, .deletedElsewhereRestored)
                await saveToServer(id, context: context)
            } else {
                await tell(id, .deletedElsewhereRestored)
            }
        }
    }

    /// Gives the draft a new Message-ID on its From domain, keeping another device's version as it is (D10).
    /// Returns the draft as forked.
    private func fork(_ id: String, draft: MessageDraft, droppingServerCopy: Bool) async -> MessageDraft? {
        var draft = draft
        draft.messageID = MessageDraft.newMessageID(domain: draft.from.flatMap { AddressParser.domain(of: $0.email) }
            ?? draft.messageIDDomain ?? "invalid")
        let messageID = draft.messageID
        let composer = host?.openComposer(draft.id)
        composer?.adopt(messageID: messageID)
        guard let content = try? MailSend.encode(composer?.draft ?? draft) else { return nil }
        _ = try? await store.updateOutbox(id: id) { row, record in
            row.content = content
            row.messageID = messageID
            row.serverRevision = nil
            if droppingServerCopy { row.serverEmailID = nil }
            record.notice = .otherVersionKept
        }
        composer?.receive(.otherVersionKept)
        return draft
    }

    /// Records a notice for the draft's composer, and shows it there if it is open.
    private func tell(_ id: String, _ notice: ComposerNotice?) async {
        _ = try? await store.updateOutbox(id: id) { _, record in record.notice = notice }
        if let notice { host?.openComposer(UUID(uuidString: id) ?? UUID())?.receive(notice) }
    }

    func clearNotice(_ id: UUID) async {
        _ = try? await store.updateOutbox(id: id.uuidString) { _, record in record.notice = nil }
    }

    // MARK: Failures and backoff

    private func fail(_ id: String, _ failure: OutboxFailure) async {
        _ = try? await store.updateOutbox(id: id) { row, record in
            guard row.state == .queued || row.state == .submitting else { return }
            row.state = .failed
            record.failure = failure
            record.notBefore = nil
            record.wait = nil
            record.lastAttempt = nil
        }
    }

    /// A request that certainly didn't run (C2): the message keeps waiting, or fails for good.
    private func notSent(_ id: String, _ error: JMAPError) async {
        if SendError.lacksSubmissionScope(error) {
            await host?.outboxLostSubmissionScope()
            return await fail(id, .tokenLacksSubmission)
        }
        switch error {
        case .unauthorized:
            host?.outboxTokenRejected()
        case _ where SendError.isNoConnection(error):
            await backOff(id, .connection)
        case _ where error.isTemporary:
            await backOff(id, .busy)
        default:
            await fail(id, .refused(type: "request", description: error.localizedDescription))
        }
    }

    /// The next try after 30 s, doubling up to 5 minutes; a returning network flushes at once anyway.
    private func backOff(_ id: String, _ wait: OutboxRecord.Wait) async {
        let now = clock.now
        _ = try? await store.updateOutbox(id: id) { row, record in
            guard row.state == .queued else { return }
            record.attempts += 1
            record.notBefore = now.addingTimeInterval(min(30 * pow(2, Double(record.attempts - 1)), 300))
            record.wait = wait
        }
    }

    /// Has the flush that just ran look again shortly, for a message that can go on right away.
    private func requestFlushSoon() {
        Task { self.requestFlush() }
    }

    // MARK: Uploads

    /// Uploads the draft's attachments that the server doesn't have, one at a time, unless that runs already.
    func startUploads(_ id: String) {
        guard isRunning, uploadTasks[id] == nil, host?.isOnline == true else { return }
        uploadTasks[id] = Task { [weak self] in
            await self?.runUploads(id)
            self?.uploadTasks[id] = nil
            for waiter in self?.uploadWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
            self?.rebuildItems()
        }
        rebuildItems()
    }

    private func runUploads(_ id: String) async {
        let end = activity.begin("Uploading attachments")
        defer { end() }
        var failed: Set<String> = []
        while isRunning, !Task.isCancelled {
            let now = clock.now
            guard let attachments = try? await store.outgoingAttachments(draftID: id),
                  let next = attachments.first(where: { Self.needsUpload($0, at: now) && !failed.contains($0.id) }),
                  let key = UUID(uuidString: next.id)
            else { return }
            uploadStates[key] = .uploading(0)
            do {
                let data = try await store.outgoingAttachmentData(id: next.id)
                if let limit = host?.account?.maxSizeUpload, data.count > limit {
                    throw OutboxFailure.tooLarge(limit: limit)
                }
                let blob = try await client.upload(data, type: next.type)
                try await store.markOutgoingAttachmentUploaded(id: next.id, blobID: blob.blobId, expiresAt: blob.expires)
                uploadStates[key] = .uploaded
            } catch let error as JMAPError where SendError.isNoConnection(error) || error.isTemporary {
                uploadStates[key] = .waiting
                return
            } catch {
                uploadStates[key] = .failed(error.localizedDescription)
                failed.insert(next.id)
            }
        }
    }

    /// An attachment to upload: never uploaded, or its upload expires within five minutes.
    private static func needsUpload(_ attachment: OutgoingAttachment, at now: Date) -> Bool {
        guard attachment.hasBytes else { return false }
        guard attachment.blobID != nil, let expires = attachment.expiresAt else { return true }
        return expires < now.addingTimeInterval(300)
    }

    /// Waits for the draft's running uploads, at most `timeout` seconds (C28).
    private func waitForUploads(_ id: String, timeout: TimeInterval) async {
        guard uploadTasks[id] != nil else { return }
        draftsWaitingForUploads.insert(id)
        defer { draftsWaitingForUploads.remove(id) }
        let clock = clock
        let deadline = clock.now.addingTimeInterval(timeout)
        var timer: Task<Void, Never>?
        await withCheckedContinuation { continuation in
            let waiter = FirstOf(continuation)
            uploadWaiters[id, default: []].append(waiter)
            timer = Task {
                try? await clock.sleep(until: deadline)
                waiter.resume()
            }
        }
        timer?.cancel()
    }

    /// The uploads of the draft the server still has, by attachment.
    private func uploadedBlobIDs(_ id: String) async -> [UUID: String] {
        let now = clock.now
        let attachments = (try? await store.outgoingAttachments(draftID: id)) ?? []
        return Dictionary(attachments.compactMap { attachment -> (UUID, String)? in
            guard let blobID = attachment.blobID, (attachment.expiresAt ?? .distantFuture) > now,
                  let key = UUID(uuidString: attachment.id)
            else { return nil }
            return (key, blobID)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Uploads everything the message still needs, waiting for uploads that already run. Returns the blob of
    /// every local attachment, or `nil` when the message has to wait (offline, busy) or failed.
    private func uploadAll(_ id: String, draft: MessageDraft) async -> [UUID: String]? {
        startUploads(id)
        await uploadTasks[id]?.value
        let now = clock.now
        let stored = (try? await store.outgoingAttachments(draftID: id)) ?? []
        var blobIDs: [UUID: String] = [:]
        for attachment in draft.attachments where attachment.source == .local {
            guard let row = stored.first(where: { $0.id == attachment.id.uuidString }) else {
                await fail(id, .attachmentDataLost(attachment.name))
                return nil
            }
            if let blobID = row.blobID, !Self.needsUpload(row, at: now) || !row.hasBytes {
                blobIDs[attachment.id] = blobID
                continue
            }
            guard row.hasBytes else {
                await fail(id, .attachmentDataLost(attachment.name))
                return nil
            }
            if case .failed(let message) = uploadStates[attachment.id] {
                await fail(id, .refused(type: "upload", description: message))
            } else {
                await backOff(id, host?.isOnline == false ? .connection : .busy)
            }
            return nil
        }
        return blobIDs
    }

    /// The draft's local attachments whose data is gone and that the server doesn't have either.
    func lostAttachments(of draft: MessageDraft) async -> [DraftAttachment] {
        let local = draft.attachments.filter { $0.source == .local }
        guard !local.isEmpty else { return [] }
        let stored = (try? await store.outgoingAttachments(draftID: draft.id.uuidString)) ?? []
        return local.filter { attachment in
            guard let row = stored.first(where: { $0.id == attachment.id.uuidString }) else { return true }
            return !row.hasBytes && row.blobID == nil
        }
    }

    // MARK: State shown

    func reload() async {
        guard let rows = try? await store.drafts() else { return }
        self.rows = rows
        rebuildItems()
    }

    private func subject(of id: String) async -> String {
        guard let row = try? await store.draft(id: id) else { return "" }
        return header(of: row)?.subject ?? ""
    }

    private func header(of row: StoredDraft) -> DraftHeader? {
        if let cached = headers[row.id], cached.revision == row.revision { return cached.header }
        guard let header = try? JSONDecoder().decode(DraftHeader.self, from: row.content) else { return nil }
        headers[row.id] = (row.revision, header)
        return header
    }

    func rebuildItems() {
        let now = clock.now
        var items: [Item] = []
        var drafts: [DraftSummary] = []
        var undoable: UndoableSend?
        for row in rows {
            guard let id = UUID(uuidString: row.id) else { continue }
            let record = row.record
            let header = header(of: row)
            let subject = header?.subject ?? ""
            let recipients = header.map { $0.to + $0.cc + $0.bcc } ?? []
            func item(_ state: State) -> Item {
                Item(id: id, subject: subject, recipients: recipients, state: state, updatedAt: row.updatedAt)
            }
            switch row.state {
            case .editing:
                if row.hasUnsyncedChanges {
                    drafts.append(DraftSummary(id: id, subject: subject, recipients: recipients, updatedAt: row.updatedAt))
                }
            case .queued:
                items.append(item(.waiting(waitReason(row, record: record, now: now))))
                if record.localDelay, let until = record.notBefore, until > now {
                    undoable = UndoableSend(id: id, subject: subject, undoUntil: until)
                }
            case .submitting:
                items.append(item(record.cancelRequested ? .cancelling : .sending))
            case .held:
                guard let submission = record.submission else {
                    items.append(item(.sending))
                    continue
                }
                let undoUntil = submission.submittedAt.addingTimeInterval(Self.undoWindow)
                let sendsAround = submission.submittedAt.addingTimeInterval(TimeInterval(Self.holdSeconds))
                items.append(item(record.cancelRequested ? .cancelling : .held(undoUntil: undoUntil, sendsAround: sendsAround)))
                if undoUntil > now, !record.cancelRequested, undoUntil > undoable?.undoUntil ?? .distantPast {
                    undoable = UndoableSend(id: id, subject: subject, undoUntil: undoUntil)
                }
            case .failed:
                items.append(item(.failed(record.failure ?? .refused(type: "unknown", description: nil))))
            }
        }
        headers = headers.filter { key, _ in rows.contains { $0.id == key } }
        if self.items != items { self.items = items }
        if unsyncedDrafts != drafts { unsyncedDrafts = drafts }
        if self.undoable != undoable { self.undoable = undoable }
    }

    private func waitReason(_ row: StoredDraft, record: OutboxRecord, now: Date) -> WaitReason {
        if record.localDelay, let until = record.notBefore, until > now { return .localUndo(until: until) }
        if host?.isOnline == false || record.wait == .connection { return .offline }
        if uploadTasks[row.id] != nil { return .uploading(UUID(uuidString: row.id).flatMap(uploadProgress)) }
        if let at = record.notBefore, at > now { return .retry(at: at) }
        if host?.account == nil { return .unknownAccount }
        return .retry(at: record.notBefore ?? now)
    }

    // MARK: Timers (C15)

    /// Sleeps until the next deadline (a retry, a release check, the end of an Undo window), then flushes.
    private func scheduleWakeUp() {
        wakeUp?.cancel()
        wakeUp = nil
        guard isRunning, let due = nextDue() else { return }
        let clock = clock
        wakeUp = Task { [weak self] in
            do { try await clock.sleep(until: due) } catch { return }
            self?.requestFlush()
        }
    }

    private func nextDue() -> Date? {
        let now = clock.now
        let online = host?.isOnline == true
        var dates: [Date] = []
        if let undoable { dates.append(undoable.undoUntil) }
        for row in rows {
            let record = row.record
            switch row.state {
            case .queued where online:
                if let at = record.notBefore { dates.append(at) }
            case .submitting where online:
                dates.append(record.verifyAt ?? now)
            case .held where online:
                if let submission = record.submission { dates.append(Self.checkDue(submission)) }
            default:
                break
            }
        }
        guard let earliest = dates.min() else { return nil }
        // Something overdue that the flush just left alone gets its next chance a little later.
        return earliest > now ? earliest : now.addingTimeInterval(5)
    }
}

/// What has to be right before a message can be sent (§3.5 `SendProblem`).
enum SendCheck {
    static func problems(
        for draft: MessageDraft, availability: SendAvailability, account: AccountSnapshot?,
        directory: SenderDirectory, policy: MaskedSending, lostAttachments: [String]
    ) -> [SendProblem] {
        var problems: [SendProblem] = []
        let recipients = draft.to + draft.cc + draft.bcc
        if recipients.isEmpty { problems.append(.noRecipients) }
        let invalid = recipients.map(\.email).filter { !AddressParser.isValid($0) }
        if !invalid.isEmpty { problems.append(.invalidAddresses(invalid)) }
        if draft.from == nil { problems.append(.noSender) }
        if availability == .tokenLacksSubmission || availability == .readOnlyAccount {
            problems.append(.cannotSend(availability))
        }
        let bytes = draft.attachments.reduce(0) { $0 + $1.size }
        if let limit = account?.maxSizeAttachmentsPerEmail, bytes > limit {
            problems.append(.attachmentsTooLarge(bytes: bytes, limit: limit))
        }
        if let limit = account?.maxSizeRequest, case let estimate = estimatedRequestBytes(draft), estimate > limit {
            problems.append(.requestTooLarge(bytes: estimate, limit: limit))
        }
        // Fixable by consent only while GoodMail may create identities; then Send asks for it instead.
        if let from = draft.from?.email, !directory.identities.isEmpty, !policy.createsIdentities,
           directory.needsSendingIdentity(for: from, policy: policy) {
            problems.append(.needsSendingIdentity(from))
        }
        if !lostAttachments.isEmpty { problems.append(.attachmentDataLost(lostAttachments)) }
        if draft.kind == .forward, draft.original?.quote.isTruncated == true {
            problems.append(.inlineForwardIncomplete)
        }
        return problems
    }

    /// An upper bound of the body's share of the `Email/set` request: the user's text written as HTML and as
    /// text, and the quote. Attachments are referenced by blob and don't count.
    static func estimatedRequestBytes(_ draft: MessageDraft) -> Int {
        let own = draft.body.characters.count * 4 * 2
        let quote = (draft.original?.quote.html?.utf8.count ?? 0) + (draft.original?.quote.text?.utf8.count ?? 0)
        let tail = (draft.preservedTail?.html.utf8.count ?? 0) + (draft.preservedTail?.text.utf8.count ?? 0)
        return own + quote + tail + 8192
    }

    /// The problems a queued message can still run into, now that the account may have changed.
    static func queuedFailure(for draft: MessageDraft) -> OutboxFailure? {
        let recipients = draft.to + draft.cc + draft.bcc
        if recipients.isEmpty { return .noRecipients }
        let invalid = recipients.map(\.email).filter { !AddressParser.isValid($0) }
        if !invalid.isEmpty { return .recipientsRejected(invalid) }
        return nil
    }
}

/// Resumes a continuation once, on whichever of several events comes first.
private final class FirstOf: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        let continuation = self.continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume()
    }
}

/// The parts of a draft's content the outbox lists, read without decoding its body or quote.
private struct DraftHeader: Decodable {
    var subject: String
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var bcc: [EmailAddress]
    var attachments: [DraftAttachment]

    private enum CodingKeys: String, CodingKey { case subject, to, cc, bcc, attachments }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        to = try container.decodeIfPresent([EmailAddress].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([EmailAddress].self, forKey: .cc) ?? []
        bcc = try container.decodeIfPresent([EmailAddress].self, forKey: .bcc) ?? []
        attachments = try container.decodeIfPresent([DraftAttachment].self, forKey: .attachments) ?? []
    }
}
