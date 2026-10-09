import Foundation
import GRDB
import JMAPKit
import Testing
@testable import MailStore

/// The store's files: where the blob file lives, what happens when a file can't be read, and how a store is
/// moved aside or destroyed.
struct StoreFilesTests {
    /// Opens a store at `folder` with an email and a cached attachment, and closes it again.
    private static func fill(_ folder: StoreFolder, key: Data, emailID: String = "e1") async throws {
        let store = try MailStore(url: folder.storeURL) { key }
        try await store.upsert([StoreFixtures.email(emailID, day: 1)])
        try await store.storeAttachment(Data([1, 2, 3]), blobId: "b1", type: "application/octet-stream")
    }

    private static func damage(_ url: URL) throws {
        try StoreFixtures.randomData(64 << 10).write(to: url)
    }

    @Test func theBlobFileSitsNextToTheStoreFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/GoodMail/Mail.sqlite")
        #expect(MailStore.blobStoreURL(forStoreAt: url).path == "/tmp/GoodMail/Mail-blobs.sqlite")

        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        let store = try MailStore(url: folder.storeURL) { key }
        try await store.storeAttachment(Data([1]), blobId: "b1", type: "application/octet-stream")
        #expect(folder.exists("Mail-blobs.sqlite"))
        #expect(!store.blobStoreWasReset)
    }

    @Test func destroyRemovesBothFilesTheirJournalsAndUnreadable() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        try await Self.fill(folder, key: key)
        MailStore.moveAside(at: folder.storeURL)
        try await Self.fill(folder, key: key)
        for journal in ["Mail.sqlite-wal", "Mail.sqlite-shm", "Mail-blobs.sqlite-wal", "Mail-blobs.sqlite-shm"] {
            try Data([0]).write(to: folder.url.appending(path: journal))
        }
        try Data([0]).write(to: folder.url.appending(path: "Other.sqlite"))

        MailStore.destroy(at: folder.storeURL)

        for name in [
            "Mail.sqlite", "Mail.sqlite-wal", "Mail.sqlite-shm", "Mail-blobs.sqlite", "Mail-blobs.sqlite-wal",
            "Mail-blobs.sqlite-shm", "Unreadable",
        ] {
            #expect(!folder.exists(name), "\(name) is still there")
        }
        #expect(folder.exists("Other.sqlite"))
    }

    @Test func moveAsideKeepsOnlyTheNewestSet() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        #expect(MailStore.moveAside(at: folder.storeURL) == nil)

        try await Self.fill(folder, key: key, emailID: "first")
        let first = try #require(MailStore.moveAside(at: folder.storeURL))
        #expect(!folder.exists("Mail.sqlite") && !folder.exists("Mail-blobs.sqlite"))
        #expect(try folder.unreadableSets() == [["Mail-blobs.sqlite", "Mail.sqlite"]])

        try await Self.fill(folder, key: key, emailID: "second")
        let second = try #require(MailStore.moveAside(at: folder.storeURL))

        #expect(second != first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try folder.unreadableSets() == [["Mail-blobs.sqlite", "Mail.sqlite"]])
        // What was moved aside is a whole store that the same key still opens.
        let recovered = try MailStore(url: second.appending(path: "Mail.sqlite")) { key }
        #expect(try await recovered.emails(ids: ["second"]).count == 1)
        #expect(try await recovered.cachedAttachment(blobId: "b1") == Data([1, 2, 3]))
        #expect(!recovered.blobStoreWasReset)
    }

    @Test func aDamagedBlobFileIsMovedAsideAndStartedAfresh() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        try await Self.fill(folder, key: key)
        try Self.damage(folder.blobURL)

        let store = try MailStore(url: folder.storeURL) { key }

        #expect(store.blobStoreWasReset)
        #expect(try await store.emails(ids: ["e1"]).count == 1)
        #expect(try await store.cachedAttachment(blobId: "b1") == nil)
        try await store.storeAttachment(Data([4]), blobId: "b2", type: "application/octet-stream")
        #expect(try await store.cachedAttachment(blobId: "b2") == Data([4]))
        #expect(folder.exists("Mail-blobs.sqlite"))
        #expect(try folder.unreadableSets() == [["Mail-blobs.sqlite"]])
    }

    @Test func aBlobFileWithAnotherKeyIsMovedAsideToo() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        try await Self.fill(folder, key: StoreFixtures.randomKey())
        // The mail database starts over with a new key, which can't read the old blob file.
        for file in MailStore.databaseFiles(folder.storeURL) {
            try? FileManager.default.removeItem(at: file)
        }
        let key = StoreFixtures.randomKey()

        do {
            let store = try MailStore(url: folder.storeURL) { key }
            #expect(store.blobStoreWasReset)
            try await store.storeAttachment(Data([4]), blobId: "b2", type: "application/octet-stream")
        }
        #expect(try folder.unreadableSets() == [["Mail-blobs.sqlite"]])

        let reopened = try MailStore(url: folder.storeURL) { key }
        #expect(!reopened.blobStoreWasReset)
        #expect(try await reopened.cachedAttachment(blobId: "b2") == Data([4]))
    }

    @Test func aBlobFileThatCantBeCreatedLeavesTheBlobsInMemory() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // A file stands where the blob file's folder would have to be.
        let blocker = folder.url.appending(path: "blocker")
        try Data([0]).write(to: blocker)
        let key = StoreFixtures.randomKey()

        let store = try MailStore(url: folder.storeURL, blobStoreURL: blocker.appending(path: "Mail-blobs.sqlite")) { key }

        #expect(store.blobStoreWasReset)
        try await store.storeAttachment(Data([5]), blobId: "b1", type: "application/octet-stream")
        #expect(try await store.cachedAttachment(blobId: "b1") == Data([5]))
        try await store.upsert([StoreFixtures.email("e1")])
        #expect(try await store.emails(ids: ["e1"]).count == 1)
    }

    @Test func aWrongKeyForTheMailDatabaseStillThrowsAndLeavesTheBlobFileAlone() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        try await Self.fill(folder, key: key)

        #expect(throws: (any Error).self) { try MailStore(url: folder.storeURL) { StoreFixtures.randomKey() } }

        #expect(!folder.exists("Unreadable"))
        let store = try MailStore(url: folder.storeURL) { key }
        #expect(!store.blobStoreWasReset)
        #expect(try await store.cachedAttachment(blobId: "b1") == Data([1, 2, 3]))
    }

    @Test func resettingTheBlobFileKeepsAnEarlierSetWithAMailDatabase() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        try await Self.fill(folder, key: key)
        let wholeSet = try #require(MailStore.moveAside(at: folder.storeURL))
        try await Self.fill(folder, key: key)

        for _ in 0..<2 {
            try Self.damage(folder.blobURL)
            #expect(try MailStore(url: folder.storeURL) { key }.blobStoreWasReset)
        }

        // The latest blob file set replaced the one before it, but not the set with a mail database.
        #expect(try folder.unreadableSets() == [["Mail-blobs.sqlite", "Mail.sqlite"], ["Mail-blobs.sqlite"]])
        #expect(FileManager.default.fileExists(atPath: wholeSet.appending(path: "Mail.sqlite").path))
    }
}
