import Foundation
import JMAPKit
import MailStore

/// Moves mail between the server and the local store.
///
/// Stored emails stay truthful through `syncChanges()`, with the user's changes queued in the store's
/// outbox applied on top until `flushPendingChanges()` sends them. Everything else here only adds
/// emails, so the calls can run in any order and repeat safely.
public struct MailSync: Sendable {
    public enum Outcome: Sendable, Equatable {
        case unchanged
        case changed
        /// The server could no longer say what changed, so the stored emails were dropped.
        case reset
    }

    public let client: JMAPClient
    public let store: MailStore

    public init(client: JMAPClient, store: MailStore) {
        self.client = client
        self.store = store
    }

    public func refreshMailboxes() async throws -> [Mailbox] {
        let mailboxes = try await client.mailboxes()
        try await store.replaceMailboxes(mailboxes)
        return mailboxes
    }

    /// Fetches and stores one page of a thread list.
    ///
    /// Pass `mailboxID` when `filter` selects exactly the contents of that mailbox; pages that connect
    /// to what is already covered then extend the mailbox's coverage.
    public func fetchThreads(
        matching filter: Filter<Email.FilterCondition>?, position: Int, limit: Int,
        extendingCoverageOf mailboxID: String? = nil
    ) async throws -> ThreadPage {
        let page = try await client.threads(matching: filter, position: position, limit: limit)
        try await store.upsert(page.threads.flatMap(\.emails))
        try await adoptStateIfFirst(page.state)

        if let mailboxID {
            let anchorDates = page.threads.compactMap { $0.anchor?.receivedAt }
            // A later page only counts if the threads before it are all covered already.
            var connects = position == 0
            if !connects, let covered = try await store.coverage(mailboxID: mailboxID) {
                connects = try await store.threadCount(matching: .init(mailboxID: mailboxID, since: covered)) >= position
            }
            let reachedEnd = position + page.threads.count >= (page.total ?? .max) || page.threads.count < limit
            if connects, let oldest = reachedEnd ? .distantPast : anchorDates.min() {
                try await store.extendCoverage(mailboxID: mailboxID, to: oldest)
            }
        }
        return page
    }

    /// Applies everything that happened on the server since the last sync.
    public func syncChanges() async throws -> Outcome {
        guard var state = try await store.emailState() else { return .unchanged }
        var outcome = Outcome.unchanged
        while true {
            let changes: EmailChangeSet
            do {
                changes = try await client.emailChanges(since: state)
            } catch JMAPError.method(let error) where error.type == MethodError.cannotCalculateChanges {
                try await store.resetEmails()
                return .reset
            }
            try await store.upsert(changes.changed)
            try await store.deleteEmails(ids: changes.destroyed)
            try await store.setEmailState(changes.newState)
            if !changes.changed.isEmpty || !changes.destroyed.isEmpty { outcome = .changed }
            guard changes.hasMoreChanges, changes.newState != state else { return outcome }
            state = changes.newState
        }
    }

    /// Fetches a whole conversation with bodies and stores it.
    public func fetchThread(_ threadId: String) async throws -> [Email] {
        let emails = try await client.emails(inThread: threadId)
        try await store.upsert(emails)
        return emails
    }

    /// Stores the next slice of all mail, newest first. Returns `false` once the whole account is stored.
    public func backfillNextPage(limit: Int = 200) async throws -> Bool {
        let cursor = try await store.backfillCursor()
        guard cursor != .distantPast else { return false }
        // Dates have whole-second resolution, so step back over the cursor's own second.
        let page = try await client.emailPage(before: cursor?.addingTimeInterval(1), limit: limit)
        try await store.upsert(page.emails)
        try await adoptStateIfFirst(page.state)

        guard !page.isLast, var oldest = page.emails.compactMap(\.receivedAt).min() else {
            try await store.extendCoverage(mailboxID: nil, to: .distantPast)
            return false
        }
        // More than a page of mail within one second would otherwise repeat forever.
        if let cursor, oldest >= cursor { oldest = cursor.addingTimeInterval(-1) }
        try await store.extendCoverage(mailboxID: nil, to: oldest)
        return true
    }

    /// Downloads bodies for recent emails that don't have one yet, so they open instantly and offline.
    /// Returns how many were stored.
    public func prefetchBodies(amongNewest window: Int = 200, limit: Int = 25) async throws -> Int {
        let ids = try await store.emailIDsMissingBody(amongNewest: window, limit: limit)
        let emails = try await client.emails(ids: ids)
        try await store.upsert(emails)
        return emails.count
    }

    /// Images larger than this are only downloaded when their message is opened.
    public static let maxPrefetchedImageSize = 2 << 20

    /// Downloads inline images of recent emails whose body is stored, as far as they fit into the
    /// image cache without evicting anything. Returns how many were stored.
    public func prefetchInlineImages(
        amongNewest window: Int = 200, limit: Int = 10, cacheLimit: Int = MailStore.inlineImageCacheLimit
    ) async throws -> Int {
        let room = cacheLimit - (try await store.inlineImageBytes())
        let images = try await store.missingInlineImages(
            amongNewest: window, maxSize: min(room, Self.maxPrefetchedImageSize), limit: limit)
        var stored = 0
        var used = 0
        for image in images where used + (image.size ?? 0) <= room {
            let data: Data
            do {
                data = try await client.download(blobId: image.blobId, type: image.type, name: "image")
            } catch let error as JMAPError where !error.isTemporary && error != .unauthorized {
                try await store.forgetInlineImage(blobId: image.blobId)
                continue
            }
            try await store.storeInlineImageData(data, blobId: image.blobId)
            used += data.count
            stored += 1
        }
        return stored
    }

    /// Downloads small attachments of recent mail into the attachment cache, as far as they fit into its free
    /// room: prefetching never evicts anything (U4, D24). Mail that is only in `mailboxIDs` (Junk and Trash) is
    /// skipped, and so is a network in Low Data Mode, by the request itself. Returns how many were stored.
    public func prefetchAttachments(
        amongNewest window: Int = 200, maxSize: Int = 1 << 20, limit: Int = 10,
        cacheLimit: Int = MailStore.attachmentCacheLimit, skipping mailboxIDs: [String] = []
    ) async throws -> Int {
        let room = cacheLimit - (try await store.attachmentCacheBytes())
        guard room > 0 else { return 0 }
        let attachments = try await store.missingAttachments(
            amongNewest: window, maxSize: min(room, maxSize), limit: limit, skippingEmailsOnlyIn: mailboxIDs)
        var stored = 0
        var used = 0
        for attachment in attachments where used + (attachment.size ?? 0) <= room {
            let data: Data
            do {
                data = try await client.download(
                    blobId: attachment.blobId, type: attachment.type, name: attachment.name ?? "attachment",
                    allowsConstrainedNetworkAccess: false)
            } catch let error as JMAPError where !error.isTemporary && error != .unauthorized {
                try await store.forgetAttachment(blobId: attachment.blobId)
                continue
            }
            guard used + data.count <= room else { break }
            try await store.storeAttachment(data, blobId: attachment.blobId, type: attachment.type, evictingBeyond: nil)
            used += data.count
            stored += 1
        }
        return stored
    }

    // MARK: Outbox

    public struct FlushResult: Sendable, Equatable {
        /// Emails whose changes the server applied.
        public var sent = 0
        /// Emails whose changes the server refused; the store has its copy of them again.
        public var rejected: [String: SetError] = [:]
    }

    /// Applies patches to the stored emails right away and queues them for the server.
    public func enqueue(_ updates: [String: PatchObject]) async throws {
        try await store.enqueue(updates)
    }

    /// Sends queued changes until none are left.
    ///
    /// A thrown error leaves the changes queued for another try, unless the server could never accept
    /// them (see ``discardsChanges(after:)``): then they are dropped so they don't block everything
    /// queued after them, as soon as the affected emails could be fetched again, and the error rethrown.
    /// Changes the server refuses one by one are dropped the same way.
    public func flushPendingChanges() async throws -> FlushResult {
        var result = FlushResult()
        while let batch = try await store.pendingChanges() {
            let ids = Set(batch.updates.keys)
            let rejected: [String: SetError]
            do {
                rejected = try await client.updateEmails(batch.updates)
            } catch {
                if Self.discardsChanges(after: error) {
                    try await restoreFromServer(ids, droppingChangesThrough: batch.throughSeq)
                }
                throw error
            }
            let missing = Set(rejected.filter { $0.value.type == SetError.notFound }.keys)
            let refused = Set(rejected.keys).subtracting(missing)
            try await store.removePendingChanges(through: batch.throughSeq, emailIDs: ids.subtracting(refused))
            try await store.deleteEmails(ids: Array(missing))
            result.sent += batch.updates.count - rejected.count
            result.rejected.merge(rejected) { _, later in later }
            try await restoreFromServer(refused, droppingChangesThrough: batch.throughSeq)
        }
        return result
    }

    /// Whether changes whose sending failed with `error` must be dropped because resending them can't
    /// succeed. Connection trouble and an invalid token are worth waiting out.
    static func discardsChanges(after error: Error) -> Bool {
        guard let error = error as? JMAPError, !error.isTemporary else { return false }
        switch error {
        case .unauthorized, .missingCapability: return false
        default: return true
        }
    }

    /// Replaces the stored copies with the server's, rebased onto any changes queued after `seq`.
    ///
    /// The changes stay queued while the server can't be asked, so the stored copies never keep
    /// showing a change that is no longer on its way; the next flush sends them again and ends up here.
    private func restoreFromServer(_ ids: Set<String>, droppingChangesThrough seq: Int64) async throws {
        guard !ids.isEmpty else { return }
        let emails: [Email]
        do {
            emails = try await client.emails(ids: Array(ids))
        } catch {
            if Self.discardsChanges(after: error) { try await store.removePendingChanges(through: seq, emailIDs: ids) }
            throw error
        }
        try await store.removePendingChanges(through: seq, emailIDs: ids)
        try await store.upsert(emails)
        try await store.deleteEmails(ids: Array(ids.subtracting(emails.map(\.id))))
    }

    private func adoptStateIfFirst(_ state: String) async throws {
        if try await store.emailState() == nil {
            try await store.setEmailState(state)
        }
    }
}
