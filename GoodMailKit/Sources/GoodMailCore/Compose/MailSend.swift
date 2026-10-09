import Foundation
import JMAPKit
import MailCompose
import MailStore

/// The mailboxes sending works with.
struct SendMailboxes: Sendable, Equatable {
    var drafts: String
    var sent: String
    var trash: String?

    var roles: MailboxRoles { MailboxRoles(drafts: drafts, sent: sent) }
}

/// What the steps need to know about the account, gathered on the main actor before a step starts.
struct SendContext: Sendable {
    var account: AccountSnapshot?
    var directory: SenderDirectory
    var mailboxes: SendMailboxes
    var policy: MaskedSending

    var availability: SendAvailability {
        account?.sendAvailability ?? .unknown
    }
}

/// The JMAP and store steps behind the outbox, like `MailSync` for reading: each reads the draft's row,
/// talks to the server and records what happened in the row before returning (§2.2, §2.3). Which step runs
/// when, and what the user sees, is up to `Outbox`.
struct MailSend: Sendable {
    let client: JMAPClient
    let store: MailStore
    let clock: any OutboxClock
    let assembly: MessageAssembly

    // MARK: Content

    static func draft(from row: StoredDraft) -> MessageDraft? {
        try? JSONDecoder().decode(MessageDraft.self, from: row.content)
    }

    /// Stable for equal drafts, so unchanged content can be told apart from a new revision.
    static func encode(_ draft: MessageDraft) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(draft)
    }

    /// The body for `draft`: its From identity's signature unless masked, and on masked sends the user's other
    /// addresses kept out of the quote (C19).
    func body(for draft: MessageDraft, context: SendContext) async -> OutgoingBody {
        let directory = context.directory
        let from = draft.from?.email
        var hidden = Set<String>()
        if let from, directory.isMasked(from), let quote = draft.original?.quote {
            for address in [quote.fromEmail] + (quote.to + quote.cc).map(\.email)
            where address.lowercased() != from.lowercased() && directory.isOwn(address) {
                hidden.insert(address.lowercased())
            }
        }
        return await assembly.body(for: draft, signature: directory.signature(for: from), hiddenAddresses: hidden)
    }

    /// The parts for the draft's attachments, from `blobIDs` (attachment id → uploaded blob) for local files.
    /// Local files without an upload are left out.
    static func attachmentParts(_ draft: MessageDraft, blobIDs: [UUID: String]) -> [EmailBodyPartCreate] {
        draft.attachments.compactMap { attachment in
            switch attachment.source {
            case .server(let blobId): MessageBuilder.attachmentPart(attachment, blobID: blobId)
            case .local: blobIDs[attachment.id].map { MessageBuilder.attachmentPart(attachment, blobID: $0) }
            }
        }
    }

    // MARK: Cleanup

    /// Destroys the row's `pendingDestroy` (D33). Destroyed and already gone both clear an entry; the rest
    /// stays for the next try. Returns whether all are gone.
    @discardableResult
    func cleanup(_ id: String) async throws -> Bool {
        guard let ids = try await store.draft(id: id)?.record.pendingDestroy, !ids.isEmpty else { return true }
        let refused = try await client.destroyEmails(ids)
        let done = Set(ids).subtracting(refused.keys)
        let row = try await store.updateOutbox(id: id) { _, record in
            record.pendingDestroy.removeAll { done.contains($0) }
        }
        return row?.record.pendingDestroy.isEmpty ?? true
    }

    // MARK: Saving drafts (§2.3)

    enum SaveOutcome: Equatable {
        case notNeeded
        /// The server has the draft as of `revision`. A lookup by Message-ID is due when the previous version
        /// was missing, or an earlier save's outcome was never learned.
        case saved(emailID: String, revision: Int64, leftOutAttachments: Bool, needsLookup: Bool, previousWasMissing: Bool)
        case refused(String)
        /// No usable answer: unknown whether the server saved it, unless `mayHaveReachedServer` is false.
        case unreachable(JMAPError)
    }

    func saveToServer(_ id: String, context: SendContext, blobIDs: [UUID: String]) async -> SaveOutcome {
        guard let row = try? await store.draft(id: id), row.state == .editing || row.state == .failed,
              row.hasUnsyncedChanges, let draft = Self.draft(from: row)
        else { return .notNeeded }
        let previousAttempt = row.record.lastAttempt
        let now = clock.now
        let stamp = OutboxRecord.stamp(now)
        guard (try? await store.updateOutbox(id: id, { _, record in record.begin(.save, at: now, stamp: stamp) })) != nil
        else { return .notNeeded }
        let attachments = Self.attachmentParts(draft, blobIDs: blobIDs)
        let body = await body(for: draft, context: context)
        let email = MessageBuilder.email(
            for: draft, body: body, attachments: attachments, draftsMailbox: context.mailboxes.drafts, sentAt: stamp)

        let result: DraftSaveResult
        do {
            result = try await client.saveDraft(email, replacing: row.serverEmailID)
        } catch {
            let error = SendError.jmap(error)
            // Waiting for a connection or a busy server is no failure to show.
            let failure = SendError.isNoConnection(error) || error.isTemporary ? nil : error.localizedDescription
            _ = try? await store.updateOutbox(id: id) { _, record in
                if !error.mayHaveReachedServer { record.lastAttempt = previousAttempt }
                record.saveFailure = failure
            }
            return .unreachable(error)
        }

        let messageID = draft.messageID
        let revision = row.revision
        guard let created = result.createdID else {
            let message = result.createError.map { $0.description ?? $0.type } ?? "Fastmail didn't save the draft."
            let destroyed = result.destroyedPrevious
            _ = try? await store.updateOutbox(id: id) { draft, record in
                if destroyed {
                    draft.serverEmailID = nil
                    draft.serverRevision = nil
                }
                record.lastAttempt = nil
                record.saveFailure = message
            }
            return .refused(message)
        }
        let needsLookup = result.previousWasMissing || previousAttempt != nil
        let saved = try? await store.updateOutbox(id: id) { draft, record in
            draft.serverEmailID = created
            draft.serverRevision = revision
            record.serverMessageID = messageID
            record.serverSavedAt = now
            record.addOwn(created)
            record.saveFailure = nil
            if !needsLookup { record.lastAttempt = nil }
        }
        guard saved != nil else {
            // Deleted meanwhile: the copy just made must not stay behind.
            _ = try? await client.destroyEmails([created])
            return .notNeeded
        }
        // An upload the draft refers to stays on the server for as long as the draft does (RFC 8620 §6).
        for attachment in draft.attachments where attachment.source == .local {
            if let blobID = blobIDs[attachment.id] {
                try? await store.markOutgoingAttachmentUploaded(
                    id: attachment.id.uuidString, blobID: blobID, expiresAt: .distantFuture)
            }
        }
        return .saved(
            emailID: created, revision: revision, leftOutAttachments: attachments.count < draft.attachments.count,
            needsLookup: needsLookup, previousWasMissing: result.previousWasMissing)
    }

    // MARK: Copies by Message-ID

    /// Copies of the message in Drafts or Sent: by the `header` filter, or, where the server ignores it, among
    /// the mail of those mailboxes received since `since` (§2.2, fallback scan). Every result is checked here
    /// rather than trusting the filter.
    func copies(of messageID: String, since: Date, mailboxes: SendMailboxes) async throws -> [MessageCopy] {
        let accountId = try await client.accountId(for: Capability.mail)
        var batch = Batch()
        let query = batch.add(EmailQuery(
            accountId: accountId, filter: .condition(.init(header: ["Message-ID", messageID])), limit: 50))
        let get = batch.add(EmailGet(
            accountId: accountId, ids: .reference(query.reference("/ids")), properties: MessageCopy.properties))
        let found = try await client.send(batch).get(get).list.map(MessageCopy.init)
        var copies = found.filter { $0.messageId.contains(messageID) }
        if copies.count != found.count {
            var scan = Batch()
            let recent = scan.add(EmailQuery(
                accountId: accountId,
                filter: .and([
                    .or([mailboxes.drafts, mailboxes.sent].map { .condition(.init(inMailbox: $0)) }),
                    .condition(.init(after: since)),
                ]),
                sort: [Comparator(property: "receivedAt", isAscending: false)], limit: 200))
            let recentGet = scan.add(EmailGet(
                accountId: accountId, ids: .reference(recent.reference("/ids")), properties: MessageCopy.properties))
            let scanned = try await client.send(scan).get(recentGet).list.map(MessageCopy.init)
            copies += scanned.filter { copy in
                copy.messageId.contains(messageID) && !copies.contains { $0.id == copy.id }
            }
        }
        return copies.filter { $0.mailboxIds[mailboxes.drafts] == true || $0.mailboxIds[mailboxes.sent] == true }
    }

    enum Conflict: Equatable {
        /// Only this composition's copies: strays from lost answers are queued for destruction.
        case none
        /// A copy that isn't a draft is in Sent: another device sent the message.
        case sentElsewhere
        /// Another device saved its own version of the draft.
        case editedElsewhere
        /// The copy this device saved is gone, deleted or moved to Trash elsewhere.
        case discardedElsewhere
    }

    enum LookupTrigger: Equatable {
        /// After a save; whether the version it replaced was missing.
        case save(previousWasMissing: Bool)
        /// The synced store no longer has the server copy in Drafts.
        case serverCopyCheck
    }

    /// The conflict lookup (§2.3): which copies with the draft's Message-ID are this composition's own (made
    /// by it, or received while one of its requests was unresolved) and which another device's. Own strays go
    /// to `pendingDestroy`; afterwards every attempt is accounted for.
    func lookUpConflicts(_ id: String, trigger: LookupTrigger, mailboxes: SendMailboxes) async throws -> Conflict {
        guard let row = try await store.draft(id: id) else { return .none }
        let record = row.record
        let since = min(record.lastAttempt?.startedAt ?? .distantFuture, record.serverSavedAt ?? record.createdAt)
            .addingTimeInterval(-600)
        let copies = try await copies(of: record.serverMessageID ?? row.messageID, since: since, mailboxes: mailboxes)
        let current = row.serverEmailID
        let others = copies.filter { $0.id != current }
        let strays = others.filter(record.isOwn).map(\.id)
        let foreign = others.filter { !record.isOwn($0) }
        _ = try await store.updateOutbox(id: id) { _, record in
            record.destroyLater(strays)
            record.lastAttempt = nil
        }

        if foreign.contains(where: { !$0.isDraft && $0.mailboxIds[mailboxes.sent] == true }) { return .sentElsewhere }
        if foreign.contains(where: { $0.isDraft && $0.mailboxIds[mailboxes.drafts] == true }) { return .editedElsewhere }
        switch trigger {
        case .save(let previousWasMissing):
            // A lost answer's request that ran replaced the previous version itself; its copy is a stray.
            return !previousWasMissing || !strays.isEmpty ? .none : .discardedElsewhere
        case .serverCopyCheck:
            let isThere = copies.contains { $0.id == current && $0.mailboxIds[mailboxes.drafts] == true }
            return isThere ? .none : .discardedElsewhere
        }
    }

    // MARK: Sending (§2.2)

    enum PreCheck: Equatable {
        case clear
        /// A copy in Sent that isn't a draft and isn't this composition's: another device sent it (C29).
        case sentElsewhere
        /// Another device's draft of it: this send goes out under a new Message-ID, that copy stays.
        case otherVersion
    }

    /// The read-only check before every submission (D14): has the composition been sent elsewhere?
    func preCheck(_ row: StoredDraft, mailboxes: SendMailboxes) async throws -> PreCheck {
        let record = row.record
        let copies = try await copies(of: row.messageID, since: record.createdAt.addingTimeInterval(-600), mailboxes: mailboxes)
        let foreign = copies.filter { $0.id != row.serverEmailID && !record.isOwn($0) }
        if foreign.contains(where: { !$0.isDraft && $0.mailboxIds[mailboxes.sent] == true }) { return .sentElsewhere }
        if foreign.contains(where: \.isDraft) { return .otherVersion }
        return .clear
    }

    enum SubmitOutcome: Equatable {
        /// Fastmail holds it for the Undo window.
        case held(OutboxRecord.Submission)
        /// Released at once (no server hold).
        case released
        /// The server refused to hold it: from now on the Undo window passes on this device (C23), for this
        /// message counted from the start of its request.
        case holdRefused(submittedAt: Date)
        case failed(OutboxFailure)
        /// These uploads are gone from the server; upload them again and retry.
        case blobsNotFound([String])
        /// Fastmail was unavailable after making the email, which is queued for destruction: try again later.
        case busy
        /// Certainly not sent: no connection, refused before running, throttled.
        case notSent(JMAPError)
        /// No usable answer that may have come after the server acted: verify before anything else (D14).
        case unknown
    }

    /// Persists `submitting` (D14), then creates the message and its submission in one request that is never
    /// repeated by itself, destroying nothing (D33). Returns `nil` if the row isn't queued any more, as when
    /// the user cancelled meanwhile.
    func submit(
        _ id: String, draft: MessageDraft, identity: Identity, blobIDs: [UUID: String], holdFor: Int?,
        context: SendContext
    ) async throws -> SubmitOutcome? {
        try MessageBuilder.checkMessageID(of: draft)
        let envelope = try MessageBuilder.envelope(for: draft, holdFor: holdFor)
        let body = await body(for: draft, context: context)
        let start = clock.now
        let stamp = OutboxRecord.stamp(start)
        let email = MessageBuilder.email(
            for: draft, body: body, attachments: Self.attachmentParts(draft, blobIDs: blobIDs),
            draftsMailbox: context.mailboxes.drafts, sentAt: stamp)
        if let limit = context.account?.maxSizeRequest,
           let size = try? JMAPCoding.makeEncoder().encode(email).count, size > limit {
            return .failed(.tooLarge(limit: limit))
        }
        let claimed = try await store.updateOutbox(id: id) { row, record in
            guard row.state == .queued else { return }
            row.state = .submitting
            record.begin(.send, at: start, stamp: stamp)
            record.wait = nil
        }
        guard claimed?.state == .submitting else { return nil }

        let result: SubmissionResult
        do {
            result = try await client.submit(
                email, identityID: identity.id, envelope: envelope, mailboxes: context.mailboxes.roles)
        } catch {
            let error = SendError.jmap(error)
            guard !error.mayHaveReachedServer else { return .unknown }
            _ = try await store.updateOutbox(id: id) { row, record in
                row.state = .queued
                record.lastAttempt = nil
            }
            return .notSent(error)
        }

        guard let emailID = result.emailID else {
            _ = try await store.updateOutbox(id: id) { row, record in
                row.state = .queued
                record.lastAttempt = nil
            }
            guard let error = result.emailError else { return .failed(.refused(type: "unknown", description: nil)) }
            if error.type == SetError.blobNotFound { return .blobsNotFound(error.notFound ?? []) }
            return .failed(OutboxFailure(error, sender: draft.from?.email ?? ""))
        }

        if let submission = result.submission, result.submissionError == nil {
            let now = clock.now
            let held = submission.undoStatus == .pending || (submission.undoStatus == nil && holdFor != nil)
            let info = OutboxRecord.Submission(
                id: submission.id, emailID: emailID, submittedAt: start, heldAt: now, sendAt: submission.sendAt)
            _ = try await store.updateOutbox(id: id) { row, record in
                record.addOwn(emailID)
                record.destroyLater([row.serverEmailID].compactMap { $0 }.filter { $0 != emailID })
                row.serverEmailID = emailID
                row.serverRevision = row.revision
                row.state = .held
                record.submission = info
                record.lastAttempt = nil
                record.notBefore = nil
                record.attempts = 0
                record.failure = nil
            }
            return held ? .held(info) : .released
        }

        // The email exists but wasn't submitted: it is a stray draft now.
        let methodError = result.submissionMethodError
        let setError = result.submissionError
        let refusesHold = holdFor != nil && setError?.type == SetError.invalidProperties
            && (setError?.properties ?? []).contains { $0.hasPrefix("envelope") }
        _ = try await store.updateOutbox(id: id) { row, record in
            record.addOwn(emailID)
            record.destroyLater([emailID])
            record.lastAttempt = nil
            row.state = .queued
        }
        if refusesHold { return .holdRefused(submittedAt: start) }
        if let methodError {
            return methodError.type == MethodError.serverUnavailable
                ? .busy : .failed(.refused(type: methodError.type, description: methodError.description))
        }
        return .failed(setError.map { OutboxFailure($0, sender: draft.from?.email ?? "") }
            ?? .refused(type: "unknown", description: nil))
    }

    enum Verification: Equatable {
        /// Nothing was created: the message waits to be sent again, after another pre-check.
        case notSent
        case held(OutboxRecord.Submission)
        case released
    }

    /// Finds out what became of a submission whose answer was lost (D14): copies made since the attempt, then
    /// their submissions. Records the outcome in the row.
    func verify(_ id: String, mailboxes: SendMailboxes) async throws -> Verification? {
        guard let row = try await store.draft(id: id), row.state == .submitting else { return nil }
        let record = row.record
        let since = (record.lastAttempt?.startedAt ?? record.createdAt).addingTimeInterval(-600)
        let copies = try await copies(of: row.messageID, since: since, mailboxes: mailboxes)
        let candidates = copies.filter { $0.id != row.serverEmailID && record.isOwn($0) }
        let now = clock.now
        guard !candidates.isEmpty else {
            _ = try await store.updateOutbox(id: id) { row, record in
                guard row.state == .submitting else { return }
                row.state = .queued
                record.lastAttempt = nil
                record.verifyAt = nil
            }
            return .notSent
        }
        let submissions = try await client.submissions(forEmailIDs: candidates.map(\.id))
        if let pending = submissions.first(where: { $0.undoStatus == .pending && $0.emailId != nil }),
           let emailID = pending.emailId {
            let info = OutboxRecord.Submission(
                id: pending.id, emailID: emailID, submittedAt: record.lastAttempt?.startedAt ?? now, heldAt: now,
                sendAt: pending.sendAt)
            let strays = candidates.map(\.id).filter { $0 != emailID }
            _ = try await store.updateOutbox(id: id) { row, record in
                record.addOwn(emailID)
                record.destroyLater(([row.serverEmailID].compactMap { $0 } + strays).filter { $0 != emailID })
                row.serverEmailID = emailID
                row.serverRevision = row.revision
                row.state = .held
                record.submission = info
                record.lastAttempt = nil
                record.verifyAt = nil
            }
            return .held(info)
        }
        if let sent = candidates.first(where: { !$0.isDraft && $0.mailboxIds[mailboxes.sent] == true }) {
            let strays = candidates.map(\.id).filter { $0 != sent.id }
            _ = try await store.updateOutbox(id: id) { row, record in
                record.addOwn(sent.id)
                record.destroyLater(([row.serverEmailID].compactMap { $0 } + strays).filter { $0 != sent.id })
                row.serverEmailID = sent.id
                record.lastAttempt = nil
                record.verifyAt = nil
            }
            return .released
        }
        // Only drafts: emails made by attempts whose submissions never came about.
        _ = try await store.updateOutbox(id: id) { row, record in
            record.destroyLater(candidates.map(\.id))
            row.state = .queued
            record.lastAttempt = nil
            record.verifyAt = nil
        }
        return .notSent
    }

    enum Release: Equatable {
        case pending
        case released
        /// The submission was cancelled and the email is back in Drafts.
        case canceled
    }

    /// Whether a held message went out (C15): its submission and its email, in one request.
    func checkRelease(_ submission: OutboxRecord.Submission, mailboxes: SendMailboxes) async throws -> Release {
        let session = try await client.session()
        let mailAccount = try session.primaryAccountId(for: Capability.mail)
        let submissionAccount = try session.primaryAccountId(for: Capability.submission)
        var batch = Batch()
        let submissions = batch.add(EmailSubmissionGet(
            accountId: submissionAccount, ids: [submission.id], properties: ["id", "undoStatus", "sendAt"]))
        let emails = batch.add(EmailGet(
            accountId: mailAccount, ids: [submission.emailID], properties: ["mailboxIds", "keywords"]))
        let response = try await client.send(batch)
        let status = try response.get(submissions).list.first?.undoStatus
        let email = try response.get(emails).list.first
        switch status {
        case .pending: return .pending
        case .final: return .released
        case .canceled: return .canceled
        case nil:
            // Fastmail deletes a submission once it is released or cancelled: the email tells which.
            guard let email else { return .released }
            return email.has(.draft) && email.mailboxIds?[mailboxes.drafts] == true ? .canceled : .released
        }
    }
}

/// How the outbox reads the errors of its requests. A namespace rather than members of `JMAPError`, which other
/// parts of the app extend too.
enum SendError {
    /// Every error the client throws is a `JMAPError`; anything else is treated as a transport failure.
    static func jmap(_ error: any Error) -> JMAPError {
        error as? JMAPError ?? .transport(error.localizedDescription)
    }

    /// The token lacks the "Email submission" scope (HTTP 403 `unknownCapability`).
    static func lacksSubmissionScope(_ error: JMAPError) -> Bool {
        if case .http(403, let type) = error { return type == "urn:ietf:params:jmap:error:unknownCapability" }
        if case .missingCapability(let capability) = error { return capability == Capability.submission }
        return false
    }

    /// The device has no connection, as opposed to the server being busy.
    static func isNoConnection(_ error: JMAPError) -> Bool {
        switch error {
        case .connection(let code, _):
            [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .timedOut].contains(code)
        case .sessionUnavailable(let error): isNoConnection(error)
        default: false
        }
    }
}

extension OutboxFailure {
    /// What a refusal of the message or its submission means for the user (§3.10).
    init(_ error: SetError, sender: String) {
        switch error.type {
        case SetError.forbiddenFrom, SetError.forbiddenMailFrom: self = .senderNotAllowed(sender)
        case SetError.tooLarge: self = .tooLarge(limit: error.maxSize)
        case SetError.invalidRecipients: self = .recipientsRejected(error.invalidRecipients ?? [])
        case SetError.noRecipients: self = .noRecipients
        case SetError.tooManyRecipients: self = .tooManyRecipients(error.maxRecipients)
        default: self = .refused(type: error.type, description: error.description)
        }
    }
}

/// What tells copies of one message apart, with the `sentAt` each create of this device sets (see
/// `OutboxRecord.isOwn(_:)`).
struct MessageCopy: Sendable, Equatable {
    let id: String
    let mailboxIds: [String: Bool]
    let keywords: [String: Bool]
    let messageId: [String]
    let receivedAt: Date?
    let sentAt: Date?

    init(_ email: Email) {
        id = email.id
        mailboxIds = email.mailboxIds ?? [:]
        keywords = email.keywords ?? [:]
        messageId = email.messageId ?? []
        receivedAt = email.receivedAt
        sentAt = email.sentAt
    }

    var isDraft: Bool {
        keywords[Email.Keyword.draft.rawValue] == true
    }

    static let properties = ["id", "mailboxIds", "keywords", "messageId", "receivedAt", "sentAt"]
}
