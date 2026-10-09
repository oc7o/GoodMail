import Foundation
import GRDB
import JMAPKit

/// A file attached to a stored email, as listed in its body structure.
public struct AttachmentRef: Sendable, Hashable {
    public let blobId: String
    public let type: String
    public let name: String?
    public let size: Int?

    public init(blobId: String, type: String, name: String?, size: Int?) {
        self.blobId = blobId
        self.type = type
        self.name = name
        self.size = size
    }
}

/// Received attachments, cached encrypted in the blob file so that opening one again works offline. Bodies
/// list their attachments in `emailAttachment`; cached bytes are dropped once no stored email refers to them.
///
/// Inline images are separate: they stay in the mail database (see "Inline images" in `MailStore.swift`).
extension MailStore {
    /// How many bytes of received attachments to keep.
    public static let attachmentCacheLimit = 500 << 20

    /// The cached attachment, marked as just used so that it is evicted last; `nil` if it isn't cached or
    /// its download hasn't finished.
    public func cachedAttachment(blobId: String) async throws -> Data? {
        guard let data = try await blobs.data(key: blobId, kind: .receivedAttachment) else { return nil }
        try await blobs.markUsed(key: blobId)
        return data
    }

    public func isAttachmentCached(blobId: String) async throws -> Bool {
        try await !blobs.completeKeys(among: [blobId], kind: .receivedAttachment).isEmpty
    }

    /// Caches a downloaded attachment, replacing an earlier copy. With `limit`, the least recently used
    /// other attachments are then evicted until the cache takes at most that many bytes.
    public func storeAttachment(
        _ data: Data, blobId: String, type: String, evictingBeyond limit: Int? = MailStore.attachmentCacheLimit
    ) async throws {
        try await blobs.store(data, key: blobId, kind: .receivedAttachment, type: type, evictingBeyond: limit)
    }

    /// Starts caching an attachment as it downloads, replacing a cached copy. It isn't visible until the
    /// writer finishes.
    public func beginAttachment(blobId: String, type: String) async throws -> BlobWriter {
        try await blobs.begin(key: blobId, kind: .receivedAttachment, type: type)
    }

    /// Writes the cached attachment to a new file at `url`, replacing what is there, one chunk at a time.
    /// Throws ``MailStoreError/attachmentNotCached(_:)``, leaving whatever is at `url` alone, if it isn't
    /// cached. A copy that fails halfway is removed.
    public func exportAttachment(blobId: String, to url: URL) async throws {
        guard try await blobs.export(key: blobId, kind: .receivedAttachment, to: url) else {
            throw MailStoreError.attachmentNotCached(blobId)
        }
        // The copy is complete; failing to move the attachment up in the eviction order doesn't undo that.
        try? await blobs.markUsed(key: blobId)
    }

    /// Writes the cached attachment to `handle` from its current offset, one chunk at a time. Throws
    /// ``MailStoreError/attachmentNotCached(_:)``, having written nothing, if it isn't cached.
    public func exportAttachment(blobId: String, into handle: FileHandle) async throws {
        guard try await blobs.export(key: blobId, kind: .receivedAttachment, into: handle) else {
            throw MailStoreError.attachmentNotCached(blobId)
        }
        try? await blobs.markUsed(key: blobId)
    }

    /// Bytes taken by cached attachments.
    public func attachmentCacheBytes() async throws -> Int {
        try await blobs.bytes(kind: .receivedAttachment)
    }

    /// Attachments of the `window` newest emails that aren't cached or being downloaded yet, newest email
    /// first. Attachments of unknown size or larger than `maxSize` bytes are left out, and so are emails that
    /// are in none but `mailboxIDs` (say, Junk and Trash).
    public func missingAttachments(
        amongNewest window: Int, maxSize: Int, limit: Int, skippingEmailsOnlyIn mailboxIDs: [String]
    ) async throws -> [AttachmentRef] {
        guard limit > 0 else { return [] }
        let candidates = try await writer.read { db in
            var arguments: StatementArguments = [window, maxSize]
            var skipping = ""
            if !mailboxIDs.isEmpty {
                let placeholders = databaseQuestionMarks(count: mailboxIDs.count)
                skipping = """
                    AND EXISTS (
                        SELECT 1 FROM emailMailbox m WHERE m.emailId = e.id AND m.mailboxId NOT IN (\(placeholders)))
                    """
                arguments += StatementArguments(mailboxIDs)
            }
            // With MAX(), SQLite takes the other columns from the row holding the maximum.
            return try Row.fetchAll(db, sql: """
                SELECT a.blobId, a.type, a.name, a.size, MAX(e.receivedAt) AS newest
                FROM (SELECT id, receivedAt FROM email ORDER BY receivedAt DESC LIMIT ?) e
                JOIN emailAttachment a ON a.emailId = e.id
                WHERE a.size <= ? \(skipping)
                GROUP BY a.blobId ORDER BY newest DESC, a.blobId
                """, arguments: arguments
            ).map { AttachmentRef(blobId: $0["blobId"], type: $0["type"], name: $0["name"], size: $0["size"]) }
        }
        let present = try await blobs.completeKeys(among: candidates.map(\.blobId), kind: .receivedAttachment)
            .union(blobs.keysBeingWritten())
        return Array(candidates.lazy.filter { !present.contains($0.blobId) }.prefix(limit))
    }

    /// Forgets an attachment, e.g. because the server can't provide it: it is no longer listed as missing
    /// and a cached copy is dropped. It is listed again if a body referring to it is stored again.
    public func forgetAttachment(blobId: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM emailAttachment WHERE blobId = ?", arguments: [blobId])
        }
        try await blobs.delete(keys: [blobId], kind: .receivedAttachment)
    }

    /// Lists the files among a body's attachment parts: all but the inline parts the HTML shows through
    /// `cid:` URLs, the rule the message view lists attachments by.
    static func recordAttachments(_ parts: [EmailBodyPart], ofEmail emailID: String, _ db: Database) throws {
        for part in parts where !(part.disposition == "inline" && part.cid != nil) {
            guard let blobId = part.blobId else { continue }
            try db.execute(
                sql: "INSERT OR IGNORE INTO emailAttachment (emailId, blobId, type, name, size) VALUES (?, ?, ?, ?, ?)",
                arguments: [emailID, blobId, part.type ?? "application/octet-stream", part.name, part.size])
        }
    }
}
