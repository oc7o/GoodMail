import Foundation
import GRDB

/// The files on disk: the mail database (`Mail.sqlite`), the blob file next to it (`Mail-blobs.sqlite`), and
/// `Unreadable/`, where copies that couldn't be opened are kept for a later version to recover.
extension MailStore {
    /// Opens the database at `url`, creating it if needed, and the blob file next to it. `key` supplies
    /// 32 random bytes.
    ///
    /// A mail database that can't be opened throws. A blob file that can't be opened never does: it is
    /// moved aside and started afresh, see ``blobStoreWasReset``.
    public convenience init(url: URL, key: @escaping @Sendable () throws -> Data) throws {
        try self.init(url: url, blobStoreURL: Self.blobStoreURL(forStoreAt: url), key: key)
    }

    /// Like ``init(url:key:)``, with the blob file at `blobStoreURL`.
    public convenience init(url: URL, blobStoreURL: URL, key: @escaping @Sendable () throws -> Data) throws {
        try self.init(url: url, blobStoreURL: blobStoreURL, key: key, now: { Date() })
    }

    convenience init(
        url: URL, blobStoreURL: URL, key: @escaping @Sendable () throws -> Data, now: @escaping @Sendable () -> Date
    ) throws {
        let writer = try Self.openDatabase(at: url, key: key)
        let (blobs, wasReset) = try Self.openBlobStore(
            at: blobStoreURL, besideStoreNamed: url.lastPathComponent, key: key, now: now)
        try self.init(writer: writer, blobs: blobs, blobStoreWasReset: wasReset, now: now)
    }

    /// The blob file of the store at `url`: `Mail-blobs.sqlite` next to `Mail.sqlite`.
    public static func blobStoreURL(forStoreAt url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent + "-blobs"
        let fileName = url.pathExtension.isEmpty ? name : "\(name).\(url.pathExtension)"
        return url.deletingLastPathComponent().appending(path: fileName)
    }

    /// Removes the store at `url` for good: the database, its blob file, their journals, and `Unreadable/`.
    public static func destroy(at url: URL) {
        for file in databaseFiles(url) + databaseFiles(blobStoreURL(forStoreAt: url)) {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: unreadableDirectory(besides: url))
    }

    /// Moves the database at `url` and its blob file, with their journals, into a new folder in
    /// `Unreadable/` next to them, so that a new store can be opened without losing the old one. Only this
    /// newest set is kept there.
    ///
    /// Returns the new folder, or `nil` if there was nothing to move.
    @discardableResult
    public static func moveAside(at url: URL) -> URL? {
        moveAside([url, blobStoreURL(forStoreAt: url)], into: unreadableDirectory(besides: url)) { _ in false }
    }

    // MARK: Opening

    /// The raw-key form of `PRAGMA key`.
    static func passphrase(forRawKey key: Data) -> String {
        "x'" + key.map { String(format: "%02x", $0) }.joined() + "'"
    }

    static func openDatabase(at url: URL, key: @escaping @Sendable () throws -> Data) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // A raw key skips SQLCipher's passphrase stretching, which a random key doesn't need.
            try db.usePassphrase(passphrase(forRawKey: key()))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    /// Opens the blob file, or replaces it if it can't be read. Never fails because of the file: a file
    /// that can't even be created leaves the blobs in memory for this session.
    ///
    /// Returns whether the bytes stored before are unavailable.
    static func openBlobStore(
        at url: URL, besideStoreNamed storeName: String, key: @escaping @Sendable () throws -> Data,
        now: @escaping @Sendable () -> Date
    ) throws -> (BlobStore, wasReset: Bool) {
        do {
            return (try BlobStore.open(at: url, storeKey: key, now: now), false)
        } catch let error as DatabaseError
                    where [ResultCode.SQLITE_NOTADB, .SQLITE_CORRUPT].contains(error.resultCode) {
            // A wrong key or a damaged file. Earlier sets that hold a mail database stay; the blob file alone
            // only holds cached attachments and the bytes of unsent ones.
            moveAside([url], into: unreadableDirectory(besides: url)) { set in
                FileManager.default.fileExists(atPath: set.appending(path: storeName).path)
            }
            if let blobs = try? BlobStore.open(at: url, storeKey: key, now: now) { return (blobs, true) }
        } catch {
            // Say, no space or no Keychain right now: the file may be fine, so it stays where it is.
        }
        return (try BlobStore.inMemory(now: now), true)
    }

    // MARK: Moving aside

    static func databaseFiles(_ url: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    static func unreadableDirectory(besides url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: "Unreadable", directoryHint: .isDirectory)
    }

    /// Moves the databases at `urls`, each with its journals, into a new folder in `unreadable`, then deletes
    /// the older folders there that `keep` doesn't want. Returns the new folder, or `nil` if nothing moved.
    @discardableResult
    static func moveAside(_ urls: [URL], into unreadable: URL, keeping keep: (URL) -> Bool) -> URL? {
        let fileManager = FileManager.default
        guard urls.flatMap(databaseFiles).contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return nil
        }
        let set = newSetDirectory(in: unreadable)
        do {
            try fileManager.createDirectory(at: set, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        func move(_ file: URL) -> Bool {
            (try? fileManager.moveItem(at: file, to: set.appending(path: file.lastPathComponent))) != nil
        }
        var movedAny = false
        for url in urls {
            if fileManager.fileExists(atPath: url.path) {
                // A database that stays keeps its journals.
                guard move(url) else { continue }
                movedAny = true
            }
            for journal in databaseFiles(url).dropFirst() where fileManager.fileExists(atPath: journal.path) {
                if move(journal) {
                    movedAny = true
                } else {
                    // Left behind, it would be applied to the new database of the same name.
                    try? fileManager.removeItem(at: journal)
                }
            }
        }
        guard movedAny else {
            try? fileManager.removeItem(at: set)
            return nil
        }
        let older = (try? fileManager.contentsOfDirectory(at: unreadable, includingPropertiesForKeys: nil)) ?? []
        for folder in older where folder.lastPathComponent != set.lastPathComponent && !keep(folder) {
            try? fileManager.removeItem(at: folder)
        }
        return set
    }

    private static func newSetDirectory(in unreadable: URL) -> URL {
        let stamp = Date().formatted(
            .iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false)
                .timeSeparator(.omitted))
        var set = unreadable.appending(path: stamp, directoryHint: .isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: set.path) {
            set = unreadable.appending(path: "\(stamp)-\(number)", directoryHint: .isDirectory)
            number += 1
        }
        return set
    }
}
