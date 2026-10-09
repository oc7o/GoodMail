import Foundation
import GRDB
import JMAPKit

/// Housekeeping that runs a slice at a time in the background.
///
/// The backfill indexes mail that was stored before attachments and correspondents were recorded. It covers
/// the rows that existed when it started (up to `boundary`, a rowid fixed by whichever comes first, an upsert
/// or maintenance); `upsert` records everything stored after that.
extension MailStore {
    /// Unreferenced cached attachments stay this long after their last use.
    static let unreferencedAttachmentLifetime: TimeInterval = 3 * 86_400
    /// Bytes without metadata are left alone this long: they may belong to an attachment still being added.
    static let outgoingOrphanGracePeriod: TimeInterval = 3600
    static let blobVacuumThreshold = 64 << 20
    static let backfillSlice = 500

    /// One slice of work. Returns whether more is waiting:
    /// - backfill `emailAttachment` from stored bodies;
    /// - index the correspondents of stored mail;
    /// - drop cached attachments no stored email refers to that went unused for 3 days, and downloads that
    ///   were interrupted;
    /// - delete outgoing bytes without metadata (metadata without bytes already reads as `hasBytes == false`);
    /// - give the blob file's free space back to the system once it exceeds 64 MB.
    public func performMaintenance() async throws -> Bool {
        try await performMaintenance(slice: Self.backfillSlice)
    }

    /// `slice`: how many emails each backfill handles at most.
    func performMaintenance(slice: Int) async throws -> Bool {
        let attachmentsWaiting = try await backfillAttachments(limit: slice)
        let correspondentsWaiting = try await backfillCorrespondents(limit: slice)
        try await dropStaleAttachments()
        try await blobs.sweepAbandonedWrites()
        try await sweepOutgoingOrphans()
        try await blobs.vacuum(ifFreeBytesExceed: Self.blobVacuumThreshold)
        return attachmentsWaiting || correspondentsWaiting
    }

    private func backfillAttachments(limit: Int) async throws -> Bool {
        try await writer.write { db in
            let progress = try Self.backfillProgress(db)
            guard progress.attachmentCursor < progress.boundary else { return false }
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, id, body FROM email
                WHERE rowid > ? AND rowid <= ? AND body IS NOT NULL ORDER BY rowid LIMIT ?
                """, arguments: [progress.attachmentCursor, progress.boundary, limit])
            let decoder = JMAPCoding.makeDecoder()
            for row in rows {
                // A body that doesn't decode is skipped rather than holding up the rest.
                guard let parts = try? decoder.decode(BodyParts.self, from: row["body"]) else { continue }
                try Self.recordAttachments(parts.attachments ?? [], ofEmail: row["id"], db)
            }
            let cursor: Int64 = rows.count < limit ? progress.boundary : rows.last!["rowid"]
            try Self.setBackfillValue(cursor, for: Self.attachmentCursorKey, db)
            return cursor < progress.boundary
        }
    }

    private func backfillCorrespondents(limit: Int) async throws -> Bool {
        try await writer.write { db in
            let progress = try Self.backfillProgress(db)
            guard progress.correspondentCursor < progress.boundary else { return false }
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, json FROM email WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?
                """, arguments: [progress.correspondentCursor, progress.boundary, limit])
            let decoder = JMAPCoding.makeDecoder()
            let roles = try Self.mailboxRoles(db)
            for row in rows {
                guard let email = try? decoder.decode(Email.self, from: row["json"]) else { continue }
                try Self.countCorrespondents(of: email, roles: roles, db)
            }
            let cursor: Int64 = rows.count < limit ? progress.boundary : rows.last!["rowid"]
            try Self.setBackfillValue(cursor, for: Self.correspondentCursorKey, db)
            return cursor < progress.boundary
        }
    }

    private func dropStaleAttachments() async throws {
        let cutoff = now().addingTimeInterval(-Self.unreferencedAttachmentLifetime)
        let stale = try await blobs.keys(kind: .receivedAttachment, lastUsedBefore: cutoff, completeOnly: true)
        guard !stale.isEmpty else { return }
        let referenced = try await writer.read { db in
            var referenced = Set<String>()
            for batch in stale.batches(of: 500) {
                referenced.formUnion(try String.fetchAll(db, sql: """
                    SELECT DISTINCT blobId FROM emailAttachment
                    WHERE blobId IN (\(databaseQuestionMarks(count: batch.count)))
                    """, arguments: StatementArguments(batch)))
            }
            return referenced
        }
        try await blobs.delete(keys: stale.filter { !referenced.contains($0) }, kind: .receivedAttachment)
    }

    private func sweepOutgoingOrphans() async throws {
        let cutoff = now().addingTimeInterval(-Self.outgoingOrphanGracePeriod)
        let prefix = Self.outgoingKey("")
        let beingWritten = blobs.keysBeingWritten()
        let keys = try await blobs.keys(kind: .outgoing, lastUsedBefore: cutoff, completeOnly: false)
            .filter { $0.hasPrefix(prefix) && !beingWritten.contains($0) }
        guard !keys.isEmpty else { return }
        let ids = keys.map { String($0.dropFirst(prefix.count)) }
        let known = try await writer.read { db in
            var known = Set<String>()
            for batch in ids.batches(of: 500) {
                known.formUnion(try String.fetchAll(db, sql: """
                    SELECT id FROM outgoingAttachment WHERE id IN (\(databaseQuestionMarks(count: batch.count)))
                    """, arguments: StatementArguments(batch)))
            }
            return known
        }
        try await blobs.delete(keys: ids.filter { !known.contains($0) }.map(Self.outgoingKey), kind: .outgoing)
    }

    // MARK: Backfill progress

    struct BackfillProgress {
        /// The last rowid stored before the backfill started.
        var boundary: Int64
        var attachmentCursor: Int64
        var correspondentCursor: Int64

        /// Whether the backfill is still going to count the correspondents of the email at `rowid`. A new
        /// email can take a rowid below the boundary if the newest stored email was deleted.
        func willIndexCorrespondents(ofRow rowid: Int64) -> Bool {
            rowid > correspondentCursor && rowid <= boundary
        }
    }

    static let backfillBoundaryKey = "MailStore.backfillBoundary"
    static let attachmentCursorKey = "MailStore.attachmentCursor"
    static let correspondentCursorKey = "MailStore.correspondentCursor"

    /// Where the backfill stands. Fixes the boundary if this is its first use since the store was created,
    /// upgraded or reset, so call it before storing new emails.
    static func backfillProgress(_ db: Database) throws -> BackfillProgress {
        let boundary: Int64
        if let stored = try backfillValue(for: backfillBoundaryKey, db) {
            boundary = stored
        } else {
            boundary = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM email") ?? 0
            try setBackfillValue(boundary, for: backfillBoundaryKey, db)
        }
        return BackfillProgress(
            boundary: boundary, attachmentCursor: try backfillValue(for: attachmentCursorKey, db) ?? 0,
            correspondentCursor: try backfillValue(for: correspondentCursorKey, db) ?? 0)
    }

    /// Starts over, for a store whose emails were all removed.
    static func resetBackfill(_ db: Database) throws {
        for key in [backfillBoundaryKey, attachmentCursorKey, correspondentCursorKey] {
            try db.execute(sql: "DELETE FROM keyedData WHERE key = ?", arguments: [key])
        }
    }

    private static func backfillValue(for key: String, _ db: Database) throws -> Int64? {
        try Data.fetchOne(db, sql: "SELECT value FROM keyedData WHERE key = ?", arguments: [key])
            .flatMap { Int64(String(decoding: $0, as: UTF8.self)) }
    }

    private static func setBackfillValue(_ value: Int64, for key: String, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO keyedData (key, value) VALUES (?, ?)",
            arguments: [key, Data(String(value).utf8)])
    }

    /// The role of each stored mailbox that has one.
    static func mailboxRoles(_ db: Database) throws -> [String: Mailbox.Role] {
        let decoder = JSONDecoder()
        var roles: [String: Mailbox.Role] = [:]
        for json in try Data.fetchAll(db, sql: "SELECT json FROM mailbox") {
            if let mailbox = try? decoder.decode(MailboxRole.self, from: json), let role = mailbox.role {
                roles[mailbox.id] = role
            }
        }
        return roles
    }

    private struct MailboxRole: Decodable {
        let id: String
        let role: Mailbox.Role?
    }

    private struct BodyParts: Decodable {
        let attachments: [EmailBodyPart]?
    }
}
