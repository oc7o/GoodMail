import Foundation
import GRDB
import JMAPKit
import Testing
@testable import MailStore

/// Inline images and Masked Email, kept so that they also show offline.
struct OfflineContentTests {
    let store = try! MailStore()

    private func email(_ id: String, day: Double, images: [(blobId: String, size: Int)]) -> Email {
        MailStoreTests.email(id, thread: id, day: day, html: "<p>Hi</p>", inlineImages: images)
    }

    private func missing(window: Int = 10, maxSize: Int = 10_000) async throws -> [String] {
        try await store.missingInlineImages(amongNewest: window, maxSize: maxSize, limit: 10).map(\.blobId)
    }

    @Test func inlineImagesOfStoredBodiesAreListedUntilDownloaded() async throws {
        try await store.upsert([
            email("e1", day: 1, images: [("shared", 100), ("large", 5000)]),
            email("e2", day: 2, images: [("shared", 100)]),
            MailStoreTests.email("e3", thread: "t3", day: 3),
        ])

        #expect(try await missing() == ["shared", "large"])
        #expect(try await missing(maxSize: 1000) == ["shared"])
        #expect(try await missing(window: 2) == ["shared"])
        #expect(try await store.missingInlineImages(amongNewest: 10, maxSize: 10_000, limit: 10).first
            == .init(blobId: "shared", type: "image/png", size: 100))

        try await store.storeInlineImageData(Data(repeating: 1, count: 100), blobId: "shared")
        #expect(try await missing() == ["large"])
        #expect(try await store.inlineImageData(blobId: "shared") == Data(repeating: 1, count: 100))
        #expect(try await store.inlineImageBytes() == 100)
    }

    @Test func downloadedImagesGoWithTheLastEmailShowingThem() async throws {
        try await store.upsert([email("e1", day: 1, images: [("shared", 3)]), email("e2", day: 2, images: [("shared", 3)])])
        try await store.storeInlineImageData(Data([1, 2, 3]), blobId: "shared")

        try await store.deleteEmails(ids: ["e2"])
        #expect(try await store.inlineImageData(blobId: "shared") != nil)

        try await store.deleteEmails(ids: ["e1"])
        #expect(try await store.inlineImageData(blobId: "shared") == nil)
        #expect(try await store.inlineImageBytes() == 0)

        try await store.upsert([email("e1", day: 1, images: [("logo", 3)])])
        try await store.storeInlineImageData(Data([1, 2, 3]), blobId: "logo")
        try await store.resetEmails()
        #expect(try await store.inlineImageBytes() == 0)
    }

    @Test func leastRecentlyUsedImagesMakeRoomForNewOnes() async throws {
        for id in ["a", "b", "c"] {
            try await store.storeInlineImageData(Data(count: 100), blobId: id)
        }
        _ = try await store.inlineImageData(blobId: "a")

        try await store.storeInlineImageData(Data(count: 100), blobId: "d", evictingBeyond: 300)

        #expect(try await store.inlineImageData(blobId: "b") == nil)
        for id in ["a", "c", "d"] {
            #expect(try await store.inlineImageData(blobId: id) != nil)
        }

        try await store.storeInlineImageData(Data(count: 301), blobId: "huge", evictingBeyond: 300)
        #expect(try await store.inlineImageData(blobId: "huge") == nil)
        #expect(try await store.inlineImageBytes() == 300)
    }

    @Test func forgottenImagesAreListedAgainWhenTheirBodyIsStoredAgain() async throws {
        let message = email("e1", day: 1, images: [("gone", 100)])
        try await store.upsert([message])

        try await store.forgetInlineImage(blobId: "gone")
        #expect(try await missing().isEmpty)

        try await store.upsert([message])
        #expect(try await missing() == ["gone"])
    }

    @Test func upgradingListsInlineImagesOfStoredBodies() async throws {
        let database = try DatabaseQueue()
        try MailStore.migrator.migrate(database, upTo: "v3")
        let message = email("e1", day: 1, images: [("logo", 420)])
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO email (id, threadId, receivedAt, isSeen, json, body) VALUES ('e1', 'e1', ?, 1, ?, ?)",
                arguments: [
                    message.receivedAt!.timeIntervalSince1970, try JMAPCoding.makeEncoder().encode(message.strippingBody()),
                    try JMAPCoding.makeEncoder().encode(message),
                ])
        }

        let store = try MailStore(writer: database)

        #expect(try await store.missingInlineImages(amongNewest: 5, maxSize: 1000, limit: 5).map(\.blobId) == ["logo"])
        #expect(try await store.maskedEmails().isEmpty)
    }

    @Test func maskedEmailsAreKeptInTheirOrder() async throws {
        let masked = try JMAPCoding.makeDecoder().decode([MaskedEmail].self, from: Data("""
            [{"id": "m2", "email": "shop.x1@fastmail.com", "state": "enabled", "forDomain": "https://shop.example",
              "description": "Shop", "createdAt": "2026-05-01T10:00:00Z", "lastMessageAt": null},
             {"id": "m1", "email": "news.y2@fastmail.com", "state": "disabled", "createdAt": "2026-04-01T08:30:00Z"}]
            """.utf8))

        try await store.replaceMaskedEmails(masked)
        #expect(try await store.maskedEmails() == masked)

        try await store.replaceMaskedEmails([masked[1]])
        #expect(try await store.maskedEmails() == [masked[1]])
    }
}
