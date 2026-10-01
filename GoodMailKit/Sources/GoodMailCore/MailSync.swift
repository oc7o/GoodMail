import Foundation
import JMAPKit
import MailStore

/// Moves mail between the server and the local store.
///
/// Stored emails stay truthful through `syncChanges()`. Everything else here only adds emails, so the
/// calls can run in any order and repeat safely.
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

    /// Applies patches to the stored emails ahead of the server and returns the previous versions.
    public func stage(_ updates: [String: PatchObject]) async throws -> [Email] {
        let originals = try await store.emails(ids: Array(updates.keys))
        try await store.upsert(originals.map { email in updates[email.id].map(email.applying) ?? email })
        return originals
    }

    /// Sends staged patches to the server, restoring `originals` if it refuses.
    public func commit(_ updates: [String: PatchObject], reverting originals: [Email]) async throws {
        do {
            try await client.updateEmails(updates)
        } catch {
            try? await store.upsert(originals)
            throw error
        }
    }

    private func adoptStateIfFirst(_ state: String) async throws {
        if try await store.emailState() == nil {
            try await store.setEmailState(state)
        }
    }
}
