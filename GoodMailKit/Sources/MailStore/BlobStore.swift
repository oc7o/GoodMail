import CryptoKit
import Foundation
import GRDB
import Synchronization

public enum MailStoreError: Error, Equatable, Sendable {
    /// No complete copy of this received attachment (by blob id) is cached.
    case attachmentNotCached(String)
    /// The bytes of this outgoing attachment are gone, e.g. because the blob file was reset.
    case outgoingBytesMissing(String)
    /// The draft doesn't exist, or no longer does.
    case draftNotFound(String)
    /// The writer was finished or aborted, or a newer write of the same blob replaced it.
    case writerClosed
}

/// The blob file: attachment bytes, in a second SQLCipher database next to the mail database.
///
/// Each blob is stored as 1 MiB chunks, so that neither writing nor reading one ever needs the whole file in
/// memory. A blob counts only once it is `complete`; an interrupted write is never read and is swept later.
final class BlobStore: Sendable {
    enum Kind: Int, Sendable {
        /// A received attachment: a cache, evicted least recently used first.
        case receivedAttachment = 1
        /// An attachment the user added to a message: the only copy until it is sent, so never evicted.
        case outgoing = 2
    }

    static let chunkSize = 1 << 20
    static let pageSize = 16_384

    let writer: any DatabaseWriter
    private let now: @Sendable () -> Date
    /// Writes in progress, by key. A newer write of the same key replaces the token, which stops the
    /// older writer instead of letting two writers interleave their chunks.
    private let activeWriters = Mutex<[String: UUID]>([:])

    init(writer: any DatabaseWriter, now: @escaping @Sendable () -> Date) throws {
        self.writer = writer
        self.now = now
        try Self.migrator.migrate(writer)
    }

    static func inMemory(now: @escaping @Sendable () -> Date) throws -> BlobStore {
        try BlobStore(writer: DatabaseQueue(), now: now)
    }

    /// Opens or creates the blob file. Its key is derived from the store key, so the Keychain keeps one key.
    static func open(
        at url: URL, storeKey: @escaping @Sendable () throws -> Data, now: @escaping @Sendable () -> Date
    ) throws -> BlobStore {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(MailStore.passphrase(forRawKey: key(fromStoreKey: storeKey())))
            // SQLCipher encrypts the header too, so a page size other than the default has to be set on
            // every connection, right after the key. Large pages suit large rows.
            try db.execute(sql: "PRAGMA cipher_page_size = \(pageSize)")
            // Only possible before the first table exists, so it takes effect for a new file. Lets
            // maintenance give the space of deleted attachments back to the system. Readers can't write it.
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try BlobStore(writer: DatabasePool(path: url.path, configuration: configuration), now: now)
    }

    static func key(fromStoreKey storeKey: Data) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: storeKey), info: Data("GoodMail blobs v1".utf8), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // chunk is a rowid table on purpose: WITHOUT ROWID suits small rows only.
            try db.execute(sql: """
                CREATE TABLE blob (
                    key TEXT PRIMARY KEY,
                    kind INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    size INTEGER NOT NULL DEFAULT 0,
                    lastUsed DOUBLE NOT NULL,
                    complete BOOLEAN NOT NULL DEFAULT 0
                );
                CREATE INDEX blob_kind_lastUsed ON blob(kind, lastUsed);
                CREATE TABLE chunk (
                    key TEXT NOT NULL REFERENCES blob(key) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    UNIQUE (key, seq)
                );
                """)
        }
        return migrator
    }

    // MARK: Writing

    /// Starts writing `key`, replacing whatever was stored under it.
    func begin(key: String, kind: Kind, type: String) async throws -> BlobWriter {
        let token = UUID()
        let now = self.now().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM blob WHERE key = ?", arguments: [key])
            try db.execute(
                sql: "INSERT INTO blob (key, kind, type, size, lastUsed, complete) VALUES (?, ?, ?, 0, ?, 0)",
                arguments: [key, kind.rawValue, type, now])
            self.activeWriters.withLock { $0[key] = token }
        }
        return BlobWriter(store: self, key: key, kind: kind, token: token)
    }

    /// Stores `data` under `key` in one transaction, replacing whatever was stored or being written there.
    func store(_ data: Data, key: String, kind: Kind, type: String, evictingBeyond limit: Int?) async throws {
        let now = self.now().timeIntervalSince1970
        try await writer.write { db in
            self.activeWriters.withLock { $0[key] = nil }
            try db.execute(sql: "DELETE FROM blob WHERE key = ?", arguments: [key])
            try db.execute(
                sql: "INSERT INTO blob (key, kind, type, size, lastUsed, complete) VALUES (?, ?, ?, 0, ?, 1)",
                arguments: [key, kind.rawValue, type, now])
            for (seq, offset) in stride(from: 0, to: data.count, by: Self.chunkSize).enumerated() {
                let start = data.startIndex + offset
                try Self.insertChunk(data[start..<min(start + Self.chunkSize, data.endIndex)], seq: seq, key: key, db)
            }
            if kind == .receivedAttachment, let limit { try Self.evictReceived(keeping: key, within: limit, db) }
        }
    }

    fileprivate func append(_ chunks: [(seq: Int, data: Data)], key: String, token: UUID) async throws {
        try await writer.write { db in
            try self.requireActive(key, token: token)
            for chunk in chunks { try Self.insertChunk(chunk.data, seq: chunk.seq, key: key, db) }
        }
    }

    fileprivate func finish(
        key: String, kind: Kind, token: UUID, lastChunk: (seq: Int, data: Data)?, evictingBeyond limit: Int?
    ) async throws {
        let now = self.now().timeIntervalSince1970
        try await writer.write { db in
            try self.requireActive(key, token: token)
            if let lastChunk { try Self.insertChunk(lastChunk.data, seq: lastChunk.seq, key: key, db) }
            try db.execute(sql: "UPDATE blob SET complete = 1, lastUsed = ? WHERE key = ?", arguments: [now, key])
            if kind == .receivedAttachment, let limit { try Self.evictReceived(keeping: key, within: limit, db) }
        }
        release(key: key, token: token)
    }

    /// Deletes what the writer with `token` wrote, unless a newer write of the same key replaced it.
    fileprivate func discard(key: String, token: UUID) async throws {
        try await writer.write { db in
            guard self.isActive(key, token: token) else { return }
            try db.execute(sql: "DELETE FROM blob WHERE key = ?", arguments: [key])
        }
        release(key: key, token: token)
    }

    /// Ends the write with `token`. Whatever it left incomplete is swept by ``sweepAbandonedWrites()``.
    fileprivate func release(key: String, token: UUID) {
        activeWriters.withLock { writers in
            if writers[key] == token { writers[key] = nil }
        }
    }

    func keysBeingWritten() -> Set<String> {
        activeWriters.withLock { Set($0.keys) }
    }

    private func isActive(_ key: String, token: UUID) -> Bool {
        activeWriters.withLock { $0[key] == token }
    }

    private func requireActive(_ key: String, token: UUID) throws {
        guard isActive(key, token: token) else { throw MailStoreError.writerClosed }
    }

    private static func insertChunk(_ data: Data, seq: Int, key: String, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO chunk (key, seq, data) VALUES (?, ?, ?)", arguments: [key, seq, data])
        try db.execute(sql: "UPDATE blob SET size = size + ? WHERE key = ?", arguments: [data.count, key])
    }

    /// Deletes the least recently used received attachments until the rest takes at most `limit` bytes.
    /// The one at `key` stays even when it alone is larger: it was just stored because it is needed now.
    private static func evictReceived(keeping key: String, within limit: Int, _ db: Database) throws {
        let kept = try Int.fetchOne(db, sql: "SELECT size FROM blob WHERE key = ?", arguments: [key]) ?? 0
        try db.execute(sql: """
            DELETE FROM blob WHERE key IN (
                SELECT key FROM (
                    SELECT key, SUM(size) OVER (ORDER BY lastUsed DESC, key) AS total
                    FROM blob WHERE kind = ? AND complete AND key != ?)
                WHERE total > ?)
            """, arguments: [Kind.receivedAttachment.rawValue, key, limit - kept])
    }

    // MARK: Reading

    /// The complete blob at `key`, or `nil`.
    func data(key: String, kind: Kind) async throws -> Data? {
        try await writer.read { db in
            guard let size = try Int.fetchOne(
                db, sql: "SELECT size FROM blob WHERE key = ? AND kind = ? AND complete",
                arguments: [key, kind.rawValue])
            else { return nil }
            var data = Data(capacity: size)
            let chunks = try Self.chunks(of: key, db)
            while let chunk = try chunks.next() {
                try chunk.withUnsafeData(atIndex: 0) { bytes in
                    if let bytes { data.append(bytes) }
                }
            }
            return data
        }
    }

    /// Writes the complete blob at `key` to `handle`, a chunk at a time. Returns `false`, having written
    /// nothing, if there is no complete blob.
    func export(key: String, kind: Kind, into handle: FileHandle) async throws -> Bool {
        try await writer.read { db in
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM blob WHERE key = ? AND kind = ? AND complete)",
                arguments: [key, kind.rawValue])!
            else { return false }
            let chunks = try Self.chunks(of: key, db)
            while let chunk = try chunks.next() {
                try chunk.withUnsafeData(atIndex: 0) { bytes in
                    if let bytes { try handle.write(contentsOf: bytes) }
                }
            }
            return true
        }
    }

    private static func chunks(of key: String, _ db: Database) throws -> RowCursor {
        try Row.fetchCursor(db, sql: "SELECT data FROM chunk WHERE key = ? ORDER BY seq", arguments: [key])
    }

    /// Which of `keys` have a complete blob.
    func completeKeys(among keys: [String], kind: Kind) async throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return try await writer.read { db in
            var found = Set<String>()
            for batch in keys.batches(of: 500) {
                found.formUnion(try String.fetchAll(db, sql: """
                    SELECT key FROM blob
                    WHERE kind = ? AND complete AND key IN (\(databaseQuestionMarks(count: batch.count)))
                    """, arguments: [kind.rawValue] + StatementArguments(batch)))
            }
            return found
        }
    }

    func markUsed(key: String) async throws {
        let now = self.now().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(sql: "UPDATE blob SET lastUsed = ? WHERE key = ?", arguments: [now, key])
        }
    }

    /// Bytes taken by complete blobs of `kind`.
    func bytes(kind: Kind) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COALESCE(SUM(size), 0) FROM blob WHERE kind = ? AND complete",
                arguments: [kind.rawValue]
            ) ?? 0
        }
    }

    /// Keys of `kind` last used (or written) before `date`, complete or not.
    func keys(kind: Kind, lastUsedBefore date: Date, completeOnly: Bool) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT key FROM blob WHERE kind = ? AND lastUsed < ? \(completeOnly ? "AND complete" : "") ORDER BY key
                """, arguments: [kind.rawValue, date.timeIntervalSince1970])
        }
    }

    // MARK: Deleting

    /// Deletes the blobs at `keys`. A write still running for one of them stops with an error.
    func delete(keys: [String], kind: Kind) async throws {
        guard !keys.isEmpty else { return }
        try await writer.write { db in
            self.activeWriters.withLock { writers in
                for key in keys { writers[key] = nil }
            }
            for batch in keys.batches(of: 500) {
                try db.execute(
                    sql: "DELETE FROM blob WHERE kind = ? AND key IN (\(databaseQuestionMarks(count: batch.count)))",
                    arguments: [kind.rawValue] + StatementArguments(batch))
            }
        }
    }

    /// Deletes blobs left incomplete by writes that ended without finishing, e.g. when the app quit mid-download.
    func sweepAbandonedWrites() async throws {
        try await writer.write { db in
            let active = self.keysBeingWritten()
            let incomplete = try String.fetchAll(db, sql: "SELECT key FROM blob WHERE NOT complete")
            for key in incomplete where !active.contains(key) {
                try db.execute(sql: "DELETE FROM blob WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Gives free pages back to the file system once they add up to more than `threshold` bytes.
    func vacuum(ifFreeBytesExceed threshold: Int) async throws {
        try await writer.writeWithoutTransaction { db in
            let freePages = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? Self.pageSize
            guard freePages * pageSize > threshold else { return }
            try db.execute(sql: "PRAGMA incremental_vacuum")
            // The file shrinks once the moved pages are checkpointed. A reader in the way just postpones it.
            _ = try? db.checkpoint(.truncate)
        }
    }
}

/// Streams one blob into the blob file, 1 MiB per transaction.
///
/// Call ``append(_:)`` in order and then ``finish(evictingBeyond:)`` or ``abort()``; calls must not overlap.
/// Until it finishes, the blob is invisible to readers.
///
/// A newer write of the same blob, or its deletion, stops this writer: its next call throws
/// ``MailStoreError/writerClosed``. When two downloads of the same attachment race, the loser can look in
/// the cache again once the winner finished.
public final class BlobWriter: Sendable {
    private struct State {
        var buffer = Data()
        var nextSeq = 0
        var byteCount = 0
        var isClosed = false
    }

    private let store: BlobStore
    private let key: String
    private let kind: BlobStore.Kind
    private let token: UUID
    private let state = Mutex(State())

    fileprivate init(store: BlobStore, key: String, kind: BlobStore.Kind, token: UUID) {
        self.store = store
        self.key = key
        self.kind = kind
        self.token = token
    }

    deinit {
        store.release(key: key, token: token)
    }

    /// The bytes appended so far.
    var byteCount: Int { state.withLock { $0.byteCount } }

    /// Adds `data` to the blob. Bytes are written whenever a whole 1 MiB chunk has come together.
    public func append(_ data: Data) async throws {
        let chunks = try state.withLock { state throws(MailStoreError) -> [(seq: Int, data: Data)] in
            guard !state.isClosed else { throw .writerClosed }
            state.buffer.append(data)
            state.byteCount += data.count
            var chunks: [(seq: Int, data: Data)] = []
            while state.buffer.count >= BlobStore.chunkSize {
                chunks.append((state.nextSeq, Data(state.buffer.prefix(BlobStore.chunkSize))))
                state.buffer = Data(state.buffer.dropFirst(BlobStore.chunkSize))
                state.nextSeq += 1
            }
            return chunks
        }
        guard !chunks.isEmpty else { return }
        try await store.append(chunks, key: key, token: token)
    }

    /// Writes what is left and makes the blob visible. For a received attachment, `limit` then evicts the
    /// least recently used other ones until the cache takes at most that many bytes; this one always stays.
    public func finish(evictingBeyond limit: Int?) async throws {
        let lastChunk = try state.withLock { state throws(MailStoreError) -> (seq: Int, data: Data)? in
            guard !state.isClosed else { throw .writerClosed }
            state.isClosed = true
            defer { state.buffer = Data() }
            return state.buffer.isEmpty ? nil : (state.nextSeq, state.buffer)
        }
        try await store.finish(key: key, kind: kind, token: token, lastChunk: lastChunk, evictingBeyond: limit)
    }

    /// Deletes everything written so far. Safe to call more than once, and after a failed `finish`.
    public func abort() async {
        state.withLock { state in
            state.isClosed = true
            state.buffer = Data()
        }
        let store = store, key = key, token = token
        // Aborting usually follows a cancellation, which would cancel this write too; a new task isn't cancelled.
        await Task { _ = try? await store.discard(key: key, token: token) }.value
    }
}

extension Array {
    func batches(of size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
