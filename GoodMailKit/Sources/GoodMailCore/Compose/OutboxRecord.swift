import Foundation
import JMAPKit
import MailStore

/// Everything the outbox has to remember about one composition between steps, kept with its `draft` row
/// (`StoredDraft.outbox`), so that a crash or quit at any point leaves enough to carry on safely (§2.2).
struct OutboxRecord: Codable, Sendable, Equatable {
    /// Requests whose outcome isn't known yet.
    struct Attempt: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case save, send, identity, cancel }
        var kind: Kind
        /// When the earliest of them started.
        var startedAt: Date
        /// The `sentAt` of each email they asked to create: every copy such a request made carries it, which
        /// tells it apart from another device's version saved at about the same time.
        var stamps: [Date] = []

        init(kind: Kind, startedAt: Date, stamps: [Date] = []) {
            self.kind = kind
            self.startedAt = startedAt
            self.stamps = stamps
        }

        private enum CodingKeys: String, CodingKey { case kind, startedAt, stamps }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Kind.self, forKey: .kind)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            stamps = try container.decodeIfPresent([Date].self, forKey: .stamps) ?? []
        }
    }

    /// A submission Fastmail accepted.
    struct Submission: Codable, Sendable, Equatable {
        var id: String
        /// The email sent: `m`, created with the submission.
        var emailID: String
        /// When the request creating it started, on this device's clock: Undo and Cancel count from here.
        var submittedAt: Date
        /// When this device learned that it is held.
        var heldAt: Date
        /// The server's release time, shown only as a hint; deadlines come from local clocks (C15).
        var sendAt: Date?
        /// How often the release was checked and found still pending.
        var checks = 0
        var nextCheckAt: Date?
    }

    /// Why a queued message waits.
    enum Wait: String, Codable, Sendable {
        /// The last attempt never reached the server.
        case connection
        /// Fastmail asked to slow down or was unavailable.
        case busy
    }

    var createdAt: Date
    /// The Message-ID of the latest server copy.
    var serverMessageID: String?
    /// When the latest server copy was made, for telling whether a later sync should have seen it.
    var serverSavedAt: Date?
    /// Every email this composition created, so lookups by Message-ID can tell its own copies from others'.
    var ownEmailIDs: [String] = []
    /// Copies to destroy: earlier versions once a submission exists, strays of failed attempts (D33).
    var pendingDestroy: [String] = []
    /// The earliest request since the last known outcome; `nil` once everything is accounted for.
    var lastAttempt: Attempt?
    var submission: Submission?
    /// A queued message isn't sent before this: a local Undo window, or a retry after a busy server.
    var notBefore: Date?
    /// Consecutive failed attempts, for the backoff.
    var attempts = 0
    var wait: Wait?
    /// Sent without a server hold (D12): the Undo window passes on this device, until `notBefore`.
    var localDelay = false
    var cancelRequested = false
    var discardRequested = false
    /// The exact address the user agreed to create a sending identity for (C24).
    var consentedSendingIdentity: String?
    var failure: OutboxFailure?
    /// What the composer has to tell when it opens.
    var notice: ComposerNotice?
    /// A draft from another client edited anyway (D32): moved to Trash once the first save of ours exists.
    var trashOnFirstSave: String?
    /// Why the last server save failed, if it did.
    var saveFailure: String?
    /// When to look again whether a submission whose answer was lost went through.
    var verifyAt: Date?

    init(createdAt: Date) {
        self.createdAt = createdAt
    }

    /// The record kept in `data`; a fresh one for a row that has none (or one this version can't read).
    static func decode(_ data: Data?, createdAt: Date) -> OutboxRecord {
        guard let data, !data.isEmpty, let record = try? JSONDecoder().decode(OutboxRecord.self, from: data) else {
            return OutboxRecord(createdAt: createdAt)
        }
        return record
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Notes a request about to go out whose outcome may stay unknown, keeping what is known of earlier ones
    /// still unresolved, whose copies may yet turn up. `stamp` is the `sentAt` of the email it creates.
    mutating func begin(_ kind: Attempt.Kind, at date: Date, stamp: Date? = nil) {
        lastAttempt = Attempt(
            kind: kind, startedAt: min(lastAttempt?.startedAt ?? date, date),
            stamps: (lastAttempt?.stamps ?? []) + [stamp].compactMap { $0 })
    }

    /// Whether this composition made `copy`: it says so, or the copy carries the `sentAt` of one of its requests
    /// whose outcome is unknown, as copies made by a request whose answer was lost, or by an automatic retry, do.
    func isOwn(_ copy: MessageCopy) -> Bool {
        if ownEmailIDs.contains(copy.id) { return true }
        guard let sentAt = copy.sentAt, let attempt = lastAttempt else { return false }
        return attempt.stamps.contains(sentAt)
    }

    /// The `sentAt` an email created at `date` gets: whole seconds, as JMAP dates are written, so that the copy
    /// carries exactly this value.
    static func stamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded(.down))
    }

    mutating func addOwn(_ id: String) {
        if !ownEmailIDs.contains(id) { ownEmailIDs.append(id) }
    }

    mutating func destroyLater(_ ids: [String]) {
        for id in ids where !pendingDestroy.contains(id) { pendingDestroy.append(id) }
    }

    /// Forgets everything about the current attempt to send, as when the message goes back to being a draft.
    mutating func resetSending() {
        submission = nil
        notBefore = nil
        attempts = 0
        wait = nil
        localDelay = false
        cancelRequested = false
        discardRequested = false
        failure = nil
        verifyAt = nil
    }

    // Fields added later decode with their defaults.
    private enum CodingKeys: String, CodingKey {
        case createdAt, serverMessageID, serverSavedAt, ownEmailIDs, pendingDestroy, lastAttempt, submission
        case notBefore, attempts, wait, localDelay, cancelRequested, discardRequested, consentedSendingIdentity
        case failure, notice, trashOnFirstSave, saveFailure, verifyAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        serverMessageID = try container.decodeIfPresent(String.self, forKey: .serverMessageID)
        serverSavedAt = try container.decodeIfPresent(Date.self, forKey: .serverSavedAt)
        ownEmailIDs = try container.decodeIfPresent([String].self, forKey: .ownEmailIDs) ?? []
        pendingDestroy = try container.decodeIfPresent([String].self, forKey: .pendingDestroy) ?? []
        lastAttempt = try container.decodeIfPresent(Attempt.self, forKey: .lastAttempt)
        submission = try container.decodeIfPresent(Submission.self, forKey: .submission)
        notBefore = try container.decodeIfPresent(Date.self, forKey: .notBefore)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        wait = try? container.decodeIfPresent(Wait.self, forKey: .wait)
        localDelay = try container.decodeIfPresent(Bool.self, forKey: .localDelay) ?? false
        cancelRequested = try container.decodeIfPresent(Bool.self, forKey: .cancelRequested) ?? false
        discardRequested = try container.decodeIfPresent(Bool.self, forKey: .discardRequested) ?? false
        consentedSendingIdentity = try container.decodeIfPresent(String.self, forKey: .consentedSendingIdentity)
        failure = try? container.decodeIfPresent(OutboxFailure.self, forKey: .failure)
        notice = try? container.decodeIfPresent(ComposerNotice.self, forKey: .notice)
        trashOnFirstSave = try container.decodeIfPresent(String.self, forKey: .trashOnFirstSave)
        saveFailure = try container.decodeIfPresent(String.self, forKey: .saveFailure)
        verifyAt = try container.decodeIfPresent(Date.self, forKey: .verifyAt)
    }
}

extension StoredDraft {
    var record: OutboxRecord {
        OutboxRecord.decode(outbox, createdAt: updatedAt)
    }

    /// Edited on this device since the latest server copy was made.
    var hasUnsyncedChanges: Bool {
        serverRevision.map { revision > $0 } ?? true
    }
}

extension MailStore {
    /// Changes the row and its outbox record in one transaction; `nil` if the row is gone.
    @discardableResult
    func updateOutbox(
        id: String, _ change: @Sendable (inout StoredDraft, inout OutboxRecord) -> Void
    ) async throws -> StoredDraft? {
        try await updateDraft(id: id) { draft in
            var record = draft.record
            change(&draft, &record)
            draft.outbox = record.encoded()
        }
    }
}
