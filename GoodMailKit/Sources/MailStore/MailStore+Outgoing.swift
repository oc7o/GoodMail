import Foundation
import GRDB

/// A file the user attached to a draft. Its bytes are in the blob file until the message is sent.
public struct OutgoingAttachment: Sendable, Equatable, Identifiable {
    public let id: String
    public let draftID: String
    public var position: Int
    public var name: String
    public var type: String
    public var size: Int
    /// The upload's blob, once uploaded.
    public var blobID: String?
    public var uploadedAt: Date?
    /// When the server forgets the upload unless a saved email refers to it.
    public var expiresAt: Date?
    /// Whether the bytes are still here. `false` after the blob file was reset: the user has to attach the
    /// file again, unless the upload is still on the server.
    public var hasBytes: Bool

    public init(
        id: String, draftID: String, position: Int, name: String, type: String, size: Int, blobID: String? = nil,
        uploadedAt: Date? = nil, expiresAt: Date? = nil, hasBytes: Bool
    ) {
        self.id = id
        self.draftID = draftID
        self.position = position
        self.name = name
        self.type = type
        self.size = size
        self.blobID = blobID
        self.uploadedAt = uploadedAt
        self.expiresAt = expiresAt
        self.hasBytes = hasBytes
    }
}

/// Attachments of drafts and of messages waiting to be sent. The metadata is a row in the mail database that
/// goes with its draft; the bytes are in the blob file, where nothing evicts them.
///
/// Adding writes the bytes first and the metadata second, and deleting removes them in the same order. A crash
/// in between leaves bytes without metadata, which maintenance deletes, or metadata without bytes, which
/// shows as ``OutgoingAttachment/hasBytes`` `false`.
extension MailStore {
    /// How long an upload lasts when the server doesn't say: the least RFC 8620 §6 guarantees.
    static let defaultUploadLifetime: TimeInterval = 3600

    static func outgoingKey(_ id: String) -> String { "outgoing:" + id }

    /// Adds the file at `url` to the draft as the attachment `id`, reading it a chunk at a time, after the
    /// draft's other attachments. Adding an `id` again replaces its bytes and forgets its upload.
    ///
    /// The draft row has to exist (``saveDraftContent(id:content:messageID:state:)``); otherwise this throws
    /// ``MailStoreError/draftNotFound(_:)`` and keeps nothing.
    public func importOutgoingAttachment(
        from file: URL, id: String, draftID: String, name: String, type: String
    ) async throws -> OutgoingAttachment {
        guard try await draftExists(draftID) else { throw MailStoreError.draftNotFound(draftID) }
        let writer = try await blobs.begin(key: Self.outgoingKey(id), kind: .outgoing, type: type)
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while true {
                let chunk = try autoreleasepool { try handle.read(upToCount: BlobStore.chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                try await writer.append(chunk)
            }
            try await writer.finish(evictingBeyond: nil)
        } catch {
            await writer.abort()
            throw error
        }
        return try await recordOutgoingAttachment(
            id: id, draftID: draftID, name: name, type: type, size: writer.byteCount)
    }

    /// Adds `data` to the draft as the attachment `id`, like ``importOutgoingAttachment(from:id:draftID:name:type:)``.
    public func addOutgoingAttachment(
        _ data: Data, id: String, draftID: String, name: String, type: String
    ) async throws -> OutgoingAttachment {
        guard try await draftExists(draftID) else { throw MailStoreError.draftNotFound(draftID) }
        try await blobs.store(data, key: Self.outgoingKey(id), kind: .outgoing, type: type, evictingBeyond: nil)
        return try await recordOutgoingAttachment(id: id, draftID: draftID, name: name, type: type, size: data.count)
    }

    /// The draft's attachments in the order they were added.
    public func outgoingAttachments(draftID: String) async throws -> [OutgoingAttachment] {
        let attachments = try await writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM outgoingAttachment WHERE draftId = ? ORDER BY position, id",
                arguments: [draftID]
            ).map { Self.outgoingAttachment($0, hasBytes: false) }
        }
        let present = try await blobs.completeKeys(among: attachments.map { Self.outgoingKey($0.id) }, kind: .outgoing)
        return attachments.map { attachment in
            var attachment = attachment
            attachment.hasBytes = present.contains(Self.outgoingKey(attachment.id))
            return attachment
        }
    }

    /// The attachment's bytes. Throws ``MailStoreError/outgoingBytesMissing(_:)`` if they are gone.
    public func outgoingAttachmentData(id: String) async throws -> Data {
        guard let data = try await blobs.data(key: Self.outgoingKey(id), kind: .outgoing) else {
            throw MailStoreError.outgoingBytesMissing(id)
        }
        return data
    }

    /// Records the upload of the attachment's bytes. `expiresAt` is when the server forgets an upload that
    /// no saved email refers to; `nil` (the server didn't say) means an hour from now.
    public func markOutgoingAttachmentUploaded(id: String, blobID: String, expiresAt: Date?) async throws {
        let now = self.now().timeIntervalSince1970
        let expiresAt = expiresAt?.timeIntervalSince1970 ?? now + Self.defaultUploadLifetime
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outgoingAttachment SET blobId = ?, uploadedAt = ?, expiresAt = ? WHERE id = ?",
                arguments: [blobID, now, expiresAt, id])
        }
    }

    /// Forgets the upload, e.g. because the server answered `blobNotFound`: `blobID`, `uploadedAt` and
    /// `expiresAt` become `nil`, so the bytes are uploaded again.
    public func markOutgoingAttachmentExpired(id: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outgoingAttachment SET blobId = NULL, uploadedAt = NULL, expiresAt = NULL WHERE id = ?",
                arguments: [id])
        }
    }

    /// Removes the attachment: its metadata and its bytes.
    public func deleteOutgoingAttachment(id: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outgoingAttachment WHERE id = ?", arguments: [id])
        }
        try await blobs.delete(keys: [Self.outgoingKey(id)], kind: .outgoing)
    }

    private func draftExists(_ id: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM draft WHERE id = ?)", arguments: [id])!
        }
    }

    /// The metadata, written once the bytes are in. If the draft went away meanwhile, so do the bytes.
    private func recordOutgoingAttachment(
        id: String, draftID: String, name: String, type: String, size: Int
    ) async throws -> OutgoingAttachment {
        let attachment = try await writer.write { db -> OutgoingAttachment? in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM draft WHERE id = ?)", arguments: [draftID])!
            else { return nil }
            try db.execute(sql: """
                INSERT INTO outgoingAttachment (id, draftId, position, name, type, size)
                VALUES (
                    ?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM outgoingAttachment WHERE draftId = ?),
                    ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    name = excluded.name, type = excluded.type, size = excluded.size,
                    blobId = NULL, uploadedAt = NULL, expiresAt = NULL
                """, arguments: [id, draftID, draftID, name, type, size])
            return try Row.fetchOne(db, sql: "SELECT * FROM outgoingAttachment WHERE id = ?", arguments: [id])
                .map { Self.outgoingAttachment($0, hasBytes: true) }
        }
        guard let attachment else {
            try? await blobs.delete(keys: [Self.outgoingKey(id)], kind: .outgoing)
            throw MailStoreError.draftNotFound(draftID)
        }
        return attachment
    }

    private static func outgoingAttachment(_ row: Row, hasBytes: Bool) -> OutgoingAttachment {
        OutgoingAttachment(
            id: row["id"], draftID: row["draftId"], position: row["position"], name: row["name"], type: row["type"],
            size: row["size"], blobID: row["blobId"],
            uploadedAt: (row["uploadedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            expiresAt: (row["expiresAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            hasBytes: hasBytes)
    }
}
