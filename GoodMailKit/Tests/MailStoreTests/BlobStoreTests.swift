import CryptoKit
import Foundation
import GRDB
import JMAPKit
import Testing
@testable import MailStore

/// Received attachments in the blob file: written in chunks, evicted least recently used first, and dropped
/// as the mail that refers to them goes.
struct BlobStoreTests {
    let clock = StoreTestClock()
    let store: MailStore

    init() throws {
        store = try MailStore(now: clock.reading)
    }

    private func cached(_ blobIds: [String]) async throws -> [String] {
        var cached: [String] = []
        for blobId in blobIds where try await store.isAttachmentCached(blobId: blobId) {
            cached.append(blobId)
        }
        return cached
    }

    // MARK: Writing and reading

    @Test func downloadsAreWrittenInChunksAndOnlyVisibleOnceFinished() async throws {
        let data = StoreFixtures.randomData(3_000_000)
        let writer = try await store.beginAttachment(blobId: "b1", type: "application/pdf")
        for offset in stride(from: 0, to: data.count, by: 300_000) {
            try await writer.append(data[offset..<min(offset + 300_000, data.count)])
        }

        #expect(try await store.chunkSizes(of: "b1") == [1 << 20, 1 << 20])
        #expect(try await store.cachedAttachment(blobId: "b1") == nil)
        #expect(try await store.isAttachmentCached(blobId: "b1") == false)
        #expect(try await store.attachmentCacheBytes() == 0)

        try await writer.finish(evictingBeyond: nil)

        #expect(try await store.chunkSizes(of: "b1") == [1 << 20, 1 << 20, 3_000_000 - (2 << 20)])
        #expect(try await store.cachedAttachment(blobId: "b1") == data)
        #expect(try await store.isAttachmentCached(blobId: "b1"))
        #expect(try await store.attachmentCacheBytes() == data.count)
        await #expect(throws: MailStoreError.writerClosed) { try await writer.append(Data([1])) }
    }

    @Test func cachedAttachmentsAreExportedToFiles() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let data = StoreFixtures.randomData((2 << 20) + 17)
        try await store.storeAttachment(data, blobId: "b1", type: "application/pdf")

        let file = folder.url.appending(path: "Report.pdf")
        try Data("old content".utf8).write(to: file)
        try await store.exportAttachment(blobId: "b1", to: file)
        #expect(try Data(contentsOf: file) == data)

        // Into a file being written, after what it holds.
        let combined = folder.url.appending(path: "combined.bin")
        try Data("head".utf8).write(to: combined)
        let handle = try FileHandle(forWritingTo: combined)
        try handle.seekToEnd()
        try await store.exportAttachment(blobId: "b1", into: handle)
        try handle.close()
        #expect(try Data(contentsOf: combined) == Data("head".utf8) + data)

        let missing = folder.url.appending(path: "missing.pdf")
        await #expect(throws: MailStoreError.attachmentNotCached("nope")) {
            try await store.exportAttachment(blobId: "nope", to: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func abortingDeletesWhatWasWritten() async throws {
        let writer = try await store.beginAttachment(blobId: "b1", type: "image/jpeg")
        try await writer.append(StoreFixtures.randomData(2_500_000))

        await writer.abort()
        await writer.abort()

        #expect(try await store.blobRowCounts() == (0, 0))
        await #expect(throws: MailStoreError.writerClosed) { try await writer.finish(evictingBeyond: nil) }
    }

    @Test func aNewerWriteOfTheSameAttachmentStopsTheOlderOne() async throws {
        let older = try await store.beginAttachment(blobId: "b1", type: "application/pdf")
        try await older.append(Data(repeating: 1, count: 1 << 20))
        let newer = try await store.beginAttachment(blobId: "b1", type: "application/pdf")

        await #expect(throws: MailStoreError.writerClosed) { try await older.append(Data(repeating: 1, count: 1 << 20)) }
        let data = StoreFixtures.randomData(1500)
        try await newer.append(data)
        await older.abort()
        try await newer.finish(evictingBeyond: nil)
        #expect(try await store.cachedAttachment(blobId: "b1") == data)

        // A whole copy stored at once wins over a download still running.
        let download = try await store.beginAttachment(blobId: "b2", type: "image/png")
        try await store.storeAttachment(Data([1, 2, 3]), blobId: "b2", type: "image/png")
        await #expect(throws: MailStoreError.writerClosed) { try await download.finish(evictingBeyond: nil) }
        #expect(try await store.cachedAttachment(blobId: "b2") == Data([1, 2, 3]))
    }

    // MARK: Eviction

    @Test func evictionKeepsTheCacheWithinItsLimitAndNeverTouchesOutgoingBytes() async throws {
        try await store.saveDraftContent(id: "d1", content: Data("{}".utf8), messageID: "m1@example.com")
        _ = try await store.addOutgoingAttachment(
            Data(repeating: 9, count: 600), id: "o1", draftID: "d1", name: "big.bin", type: "application/octet-stream")
        for blobId in ["a", "b", "c"] {
            try await store.storeAttachment(Data(count: 100), blobId: blobId, type: "image/png", evictingBeyond: nil)
            clock.advance(seconds: 60)
        }
        _ = try await store.cachedAttachment(blobId: "a")
        clock.advance(seconds: 60)

        try await store.storeAttachment(Data(count: 100), blobId: "d", type: "image/png", evictingBeyond: 300)

        #expect(try await cached(["a", "b", "c", "d"]) == ["a", "c", "d"])
        #expect(try await store.attachmentCacheBytes() == 300)

        // One larger than the whole cache stays, since it is wanted right now; everything else goes.
        clock.advance(seconds: 60)
        let writer = try await store.beginAttachment(blobId: "huge", type: "video/mp4")
        try await writer.append(Data(count: 400))
        try await writer.finish(evictingBeyond: 300)

        #expect(try await cached(["a", "c", "d", "huge"]) == ["huge"])
        #expect(try await store.attachmentCacheBytes() == 400)
        #expect(try await store.outgoingAttachments(draftID: "d1").map(\.hasBytes) == [true])
        #expect(try await store.outgoingAttachmentData(id: "o1") == Data(repeating: 9, count: 600))
    }

    // MARK: Following the stored mail

    @Test func missingAttachmentsAreThoseOfRecentMailNotCachedYet() async throws {
        try await store.replaceMailboxes(StoreFixtures.standardMailboxes)
        try await store.upsert([
            StoreFixtures.email("e1", day: 1, files: [
                .init(blobId: "small", name: "a.pdf", size: 500), .init(blobId: "large", size: 2000),
                .init(blobId: "unknown", size: nil), .init(blobId: "logo", type: "image/png", size: 100, inline: true),
            ]),
            StoreFixtures.email("e2", in: ["junk"], day: 2, files: [.init(blobId: "spam", size: 100)]),
            StoreFixtures.email("e3", in: ["inbox", "trash"], day: 3, files: [.init(blobId: "kept", size: 100)]),
            StoreFixtures.email("e4", day: 4),
        ])
        func missing(window: Int = 10, skipping: [String] = ["junk", "trash"]) async throws -> [String] {
            try await store.missingAttachments(
                amongNewest: window, maxSize: 1000, limit: 10, skippingEmailsOnlyIn: skipping
            ).map(\.blobId)
        }

        #expect(try await missing() == ["kept", "small"])
        #expect(try await missing(window: 2) == ["kept"])
        #expect(try await missing(skipping: []) == ["kept", "spam", "small"])
        #expect(try await store.missingAttachments(
            amongNewest: 10, maxSize: 1000, limit: 1, skippingEmailsOnlyIn: ["junk", "trash"])
            == [AttachmentRef(blobId: "kept", type: "application/pdf", name: nil, size: 100)])

        try await store.storeAttachment(Data(count: 100), blobId: "kept", type: "application/pdf")
        let download = try await store.beginAttachment(blobId: "small", type: "application/pdf")
        #expect(try await missing().isEmpty)
        await download.abort()
        #expect(try await missing() == ["small"])

        try await store.forgetAttachment(blobId: "small")
        #expect(try await missing().isEmpty)
        try await store.upsert([StoreFixtures.email("e1", day: 1, files: [.init(blobId: "small", name: "a.pdf", size: 500)])])
        #expect(try await missing() == ["small"])
    }

    @Test func deletingEmailsDropsTheAttachmentsNoOtherEmailRefersTo() async throws {
        try await store.upsert([
            StoreFixtures.email("e1", day: 1, files: [.init(blobId: "shared"), .init(blobId: "own")]),
            StoreFixtures.email("e2", day: 2, files: [.init(blobId: "shared")]),
        ])
        for blobId in ["shared", "own", "unrelated"] {
            try await store.storeAttachment(Data(count: 10), blobId: blobId, type: "application/pdf")
        }

        try await store.deleteEmails(ids: ["e1"])
        #expect(try await cached(["shared", "own", "unrelated"]) == ["shared", "unrelated"])

        try await store.deleteEmails(ids: ["e2"])
        // An attachment no stored email ever referred to is left to maintenance.
        #expect(try await cached(["shared", "own", "unrelated"]) == ["unrelated"])
    }

    @Test func resetKeepsTheCacheAndMaintenanceDropsWhatStaysUnreferenced() async throws {
        try await store.upsert([
            StoreFixtures.email("e1", day: 1, files: [.init(blobId: "a"), .init(blobId: "b")]),
            StoreFixtures.email("e2", day: 2, files: [.init(blobId: "c")]),
        ])
        for blobId in ["a", "b", "c"] {
            try await store.storeAttachment(Data(count: 10), blobId: blobId, type: "application/pdf")
        }

        try await store.resetEmails()
        #expect(try await store.attachmentCacheBytes() == 30)

        // Only a comes back with a stored body; b is opened again, c isn't.
        try await store.upsert([StoreFixtures.email("e1", day: 1, files: [.init(blobId: "a")])])
        clock.advance(days: 2)
        _ = try await store.cachedAttachment(blobId: "b")
        try await store.maintainFully()
        #expect(try await cached(["a", "b", "c"]) == ["a", "b", "c"])

        clock.advance(days: 1.5)
        try await store.maintainFully()
        #expect(try await cached(["a", "b", "c"]) == ["a", "b"])

        clock.advance(days: 30)
        try await store.maintainFully()
        #expect(try await cached(["a", "b", "c"]) == ["a"])
    }

    @Test func maintenanceSweepsDownloadsThatNeverFinished() async throws {
        var abandoned: BlobWriter? = try await store.beginAttachment(blobId: "abandoned", type: "application/pdf")
        try await abandoned?.append(Data(count: 1 << 20))
        abandoned = nil
        let running = try await store.beginAttachment(blobId: "running", type: "application/pdf")
        try await running.append(Data(count: 1 << 20))

        try await store.maintainFully()

        #expect(try await store.chunkSizes(of: "abandoned").isEmpty)
        #expect(try await store.chunkSizes(of: "running") == [1 << 20])
        try await running.finish(evictingBeyond: nil)
        #expect(try await store.attachmentCacheBytes() == 1 << 20)
    }

    // MARK: The file

    @Test func theBlobFileIsEncryptedWithItsOwnKeyAndLargePages() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        let marker = Data("TOPSECRETATTACHMENT".utf8)
        do {
            let store = try MailStore(url: folder.storeURL) { key }
            try await store.storeAttachment(marker + Data(count: 100_000), blobId: "b1", type: "text/plain")
            let pragmas = try await store.blobs.writer.read { db in
                try ["cipher_page_size", "page_size", "auto_vacuum"].map { try String.fetchOne(db, sql: "PRAGMA \($0)") }
            }
            #expect(pragmas == ["16384", "16384", "2"])
        }

        let raw = try Data(contentsOf: folder.blobURL)
            + ((try? Data(contentsOf: URL(fileURLWithPath: folder.blobURL.path + "-wal"))) ?? Data())
        #expect(raw.range(of: marker) == nil)
        #expect(raw.range(of: Data("SQLite format 3".utf8)) == nil)

        func opens(withKey blobKey: Data) -> Bool {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.usePassphrase(MailStore.passphrase(forRawKey: blobKey))
                try db.execute(sql: "PRAGMA cipher_page_size = 16384")
            }
            let count = try? DatabaseQueue(path: folder.blobURL.path, configuration: configuration).read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blob")
            }
            return count == 1
        }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key), info: Data("GoodMail blobs v1".utf8), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        #expect(opens(withKey: derived))
        #expect(!opens(withKey: key))
    }

    @Test func maintenanceGivesTheSpaceOfDeletedAttachmentsBack() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        let store = try MailStore(url: folder.storeURL) { key }
        for index in 0..<8 {
            try await store.storeAttachment(
                Data(repeating: UInt8(index), count: 1 << 20), blobId: "b\(index)", type: "application/octet-stream",
                evictingBeyond: nil)
        }
        func fileSize() async throws -> Int {
            try await store.blobs.writer.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
            return try FileManager.default.attributesOfItem(atPath: folder.blobURL.path)[.size] as! Int
        }
        let full = try await fileSize()
        for index in 0..<8 {
            try await store.forgetAttachment(blobId: "b\(index)")
        }
        #expect(try await fileSize() == full)

        try await store.blobs.vacuum(ifFreeBytesExceed: 0)

        #expect(full > 8 << 20)
        #expect(try await fileSize() < 1 << 20)
    }
}
