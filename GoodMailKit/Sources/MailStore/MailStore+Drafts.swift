import Foundation
import GRDB

/// Where a composition stands on its way to being sent.
public enum DraftState: Int, Sendable, Codable {
    case editing = 0, queued = 1, submitting = 2, held = 3, failed = 4
}

/// One composition: a draft being written, or a message waiting in the outbox. The store keeps `content` and
/// `outbox` as opaque bytes; what they hold is up to the caller.
public struct StoredDraft: Sendable, Equatable, Identifiable {
    public let id: String
    /// Grows with every save of the content.
    public var revision: Int64
    public var content: Data
    public var messageID: String
    /// The latest copy on the server, and the revision it was made from.
    public var serverEmailID: String?
    public var serverRevision: Int64?
    public var state: DraftState
    /// When the message last joined the outbox; orders it there.
    public var queuedAt: Date?
    public var outbox: Data?
    public var updatedAt: Date

    public init(
        id: String, revision: Int64, content: Data, messageID: String, serverEmailID: String? = nil,
        serverRevision: Int64? = nil, state: DraftState = .editing, queuedAt: Date? = nil, outbox: Data? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.revision = revision
        self.content = content
        self.messageID = messageID
        self.serverEmailID = serverEmailID
        self.serverRevision = serverRevision
        self.state = state
        self.queuedAt = queuedAt
        self.outbox = outbox
        self.updatedAt = updatedAt
    }
}

/// Drafts and the outbox of messages to send: everything here exists only on this device until it is sent
/// or saved to the server, so nothing but an explicit delete removes it.
extension MailStore {
    /// The drafts in `states` (all of them with `nil`), in outbox order: by `queuedAt`, the ones never
    /// queued last, then by `updatedAt`.
    public func drafts(in states: Set<DraftState>? = nil) async throws -> [StoredDraft] {
        try await writer.read { db in
            var sql = "SELECT * FROM draft"
            var arguments = StatementArguments()
            if let states {
                guard !states.isEmpty else { return [] }
                sql += " WHERE state IN (\(databaseQuestionMarks(count: states.count)))"
                arguments = StatementArguments(states.map(\.rawValue).sorted())
            }
            sql += " ORDER BY queuedAt IS NULL, queuedAt, updatedAt, id"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.storedDraft)
        }
    }

    public func draft(id: String) async throws -> StoredDraft? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM draft WHERE id = ?", arguments: [id]).map(Self.storedDraft)
        }
    }

    /// The draft whose latest server copy is the email `serverEmailID`.
    public func draft(serverEmailID: String) async throws -> StoredDraft? {
        try await writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM draft WHERE serverEmailId = ? ORDER BY updatedAt DESC, id LIMIT 1",
                arguments: [serverEmailID]
            ).map(Self.storedDraft)
        }
    }

    /// Saves the content of draft `id`, creating it at revision 1 if needed, and returns the new revision.
    ///
    /// With `state`, the state changes in the same transaction, e.g. to queue the message as it is sent.
    /// Entering `.queued` from another state stamps `queuedAt`; returning to `.editing` clears it.
    @discardableResult
    public func saveDraftContent(
        id: String, content: Data, messageID: String, state: DraftState? = nil
    ) async throws -> Int64 {
        let now = self.now().timeIntervalSince1970
        return try await writer.write { db in
            guard let existing = try Row.fetchOne(
                db, sql: "SELECT revision, state, queuedAt FROM draft WHERE id = ?", arguments: [id])
            else {
                let state = state ?? .editing
                try db.execute(sql: """
                    INSERT INTO draft (id, revision, content, messageId, state, queuedAt, updatedAt)
                    VALUES (?, 1, COALESCE(?, X''), ?, ?, ?, ?)
                    """, arguments: [id, content, messageID, state.rawValue, state == .queued ? now : nil, now])
                return 1
            }
            let revision: Int64 = existing["revision"] + 1
            let oldState: Int = existing["state"]
            var queuedAt: Double? = existing["queuedAt"]
            let newState = state?.rawValue ?? oldState
            if newState != oldState {
                switch DraftState(rawValue: newState) {
                case .queued: queuedAt = now
                case .editing: queuedAt = nil
                default: break
                }
            }
            // An UPDATE, not a REPLACE, which would delete the row and with it the draft's attachments.
            try db.execute(sql: """
                UPDATE draft SET revision = ?, content = COALESCE(?, X''), messageId = ?, state = ?, queuedAt = ?,
                    updatedAt = ?
                WHERE id = ?
                """, arguments: [revision, content, messageID, newState, queuedAt, now, id])
            return revision
        }
    }

    /// Changes draft `id` in one transaction and returns it as stored, or `nil` if there is no such draft.
    ///
    /// `updatedAt` becomes the current time if anything changed, unless `change` sets it itself.
    @discardableResult
    public func updateDraft(id: String, _ change: @Sendable (inout StoredDraft) -> Void) async throws -> StoredDraft? {
        let now = Date(timeIntervalSince1970: self.now().timeIntervalSince1970)
        return try await writer.write { db in
            guard let original = try Row.fetchOne(db, sql: "SELECT * FROM draft WHERE id = ?", arguments: [id])
                .map(Self.storedDraft)
            else { return nil }
            var draft = original
            change(&draft)
            guard draft != original else { return original }
            if draft.updatedAt == original.updatedAt { draft.updatedAt = now }
            // Empty Data binds as NULL, which would turn an empty outbox record into none.
            try db.execute(sql: """
                UPDATE draft SET revision = ?, content = COALESCE(?, X''), messageId = ?, serverEmailId = ?,
                    serverRevision = ?, state = ?, queuedAt = ?, outbox = CASE WHEN ? THEN X'' ELSE ? END, updatedAt = ?
                WHERE id = ?
                """, arguments: [
                    draft.revision, draft.content, draft.messageID, draft.serverEmailID, draft.serverRevision,
                    draft.state.rawValue, draft.queuedAt?.timeIntervalSince1970, draft.outbox?.isEmpty == true,
                    draft.outbox, draft.updatedAt.timeIntervalSince1970, id,
                ])
            return try Row.fetchOne(db, sql: "SELECT * FROM draft WHERE id = ?", arguments: [id]).map(Self.storedDraft)
        }
    }

    /// Deletes draft `id` with its attachments, their metadata and their bytes.
    public func deleteDraft(id: String) async throws {
        let attachmentIDs = try await writer.write { db in
            let ids = try String.fetchAll(
                db, sql: "SELECT id FROM outgoingAttachment WHERE draftId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM draft WHERE id = ?", arguments: [id])
            return ids
        }
        try await blobs.delete(keys: attachmentIDs.map(Self.outgoingKey), kind: .outgoing)
    }

    private static func storedDraft(_ row: Row) -> StoredDraft {
        StoredDraft(
            id: row["id"], revision: row["revision"], content: row["content"], messageID: row["messageId"],
            serverEmailID: row["serverEmailId"], serverRevision: row["serverRevision"],
            state: DraftState(rawValue: row["state"]) ?? .editing,
            queuedAt: (row["queuedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            outbox: row["outbox"],
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]))
    }
}
