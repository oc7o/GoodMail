import Foundation
import GRDB
import JMAPKit
import Testing
@testable import MailStore

/// Upgrading a store from M1 (v4): drafts, attachments, correspondents and keyed data arrive as new tables,
/// and the mail already stored is indexed afterwards by maintenance.
struct MigrationV5Tests {
    /// A database as M1 left it, holding these mailboxes and emails.
    private static func v4Database(mailboxes: [Mailbox] = [], emails: [Email]) async throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try MailStore.migrator.migrate(database, upTo: "v4")
        try await database.write { db in
            let encoder = JMAPCoding.makeEncoder()
            for (position, mailbox) in mailboxes.enumerated() {
                try db.execute(
                    sql: "INSERT INTO mailbox (id, position, json) VALUES (?, ?, ?)",
                    arguments: [mailbox.id, position, try JSONEncoder().encode(mailbox)])
            }
            for email in emails {
                try db.execute(
                    sql: "INSERT INTO email (id, threadId, receivedAt, isSeen, json, body) VALUES (?, ?, ?, 1, ?, ?)",
                    arguments: [
                        email.id, email.threadId!, email.receivedAt!.timeIntervalSince1970,
                        try encoder.encode(email.strippingBody()), email.hasBody ? try encoder.encode(email) : nil,
                    ])
                for mailboxID in (email.mailboxIds ?? [:]).keys {
                    try db.execute(
                        sql: "INSERT INTO emailMailbox (mailboxId, emailId) VALUES (?, ?)", arguments: [mailboxID, email.id])
                }
                // What v4 records for every stored body.
                for part in email.inlineImageParts {
                    try db.execute(
                        sql: "INSERT INTO inlineImage (emailId, blobId, type, size) VALUES (?, ?, ?, ?)",
                        arguments: [email.id, part.blobId, part.type, part.size])
                }
            }
        }
        return database
    }

    /// Stands for an email the upgrade would fail on if it decoded stored rows.
    private static func insertUndecodableEmail(_ id: String, into database: DatabaseQueue) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO email (id, threadId, receivedAt, isSeen, json, body) VALUES (?, ?, 0, 1, x'00', x'00')",
                arguments: [id, id])
        }
    }

    private static func inlineImageRows(_ database: DatabaseQueue) async throws -> [String] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM inlineImage ORDER BY emailId, blobId").map(\.description)
                + Row.fetchAll(db, sql: "SELECT * FROM inlineImageData ORDER BY blobId").map(\.description)
        }
    }

    @Test func upgradingOnlyAddsTablesAndLeavesInlineImagesAlone() async throws {
        let logo = StoreFixtures.File(blobId: "logo", type: "image/png", size: 420, inline: true)
        let photo = StoreFixtures.File(blobId: "photo", type: "image/png", size: 5000, inline: true)
        let database = try await Self.v4Database(emails: [
            StoreFixtures.email("e1", day: 1, files: [logo, .init(blobId: "report", name: "Report.pdf", size: 900)]),
            StoreFixtures.email("e2", day: 2, files: [photo]),
        ])
        try await Self.insertUndecodableEmail("broken", into: database)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO inlineImageData (blobId, size, lastUsed, data) VALUES ('logo', 3, 7, x'010203')")
        }
        let imagesBefore = try await Self.inlineImageRows(database)

        let store = try MailStore(writer: database)

        let tables = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(Set(tables).isSuperset(of: [
            "emailAttachment", "draft", "outgoingAttachment", "correspondent", "unsubscription", "keyedData",
        ]))
        #expect(try await Self.inlineImageRows(database) == imagesBefore)
        #expect(try await store.missingInlineImages(amongNewest: 10, maxSize: 10_000, limit: 10).map(\.blobId) == ["photo"])
        #expect(try await store.inlineImageData(blobId: "logo") == Data([1, 2, 3]))
        // Nothing was read from the stored rows: that is left to maintenance.
        #expect(try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emailAttachment") } == 0)
        #expect(try await store.missingAttachments(
            amongNewest: 10, maxSize: .max, limit: 10, skippingEmailsOnlyIn: []).isEmpty)
    }

    @Test func anInconsistencyLeftByAnEarlierVersionDoesntStopTheUpgrade() async throws {
        let database = try await Self.v4Database(emails: [])
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "INSERT INTO emailMailbox (mailboxId, emailId) VALUES ('inbox', 'gone')")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let store = try MailStore(writer: database)

        try await store.saveDraftContent(id: "d1", content: Data("{}".utf8), messageID: "m1@example.com")
        #expect(try await store.drafts().map(\.id) == ["d1"])
    }

    @Test func maintenanceIndexesMailStoredBeforeTheUpgradeASliceAtATime() async throws {
        let database = try await Self.v4Database(mailboxes: StoreFixtures.standardMailboxes, emails: [
            StoreFixtures.email("e1", day: 1, files: [.init(blobId: "report", name: "Report.pdf", size: 900)]),
            StoreFixtures.email(
                "e2", in: ["sent"], day: 2, from: ["Alex Berg <alex@example.com>"], to: ["Jonas Weber <jonas@example.com>"]),
        ])
        try await Self.insertUndecodableEmail("broken", into: database)
        // A clock before the emails' dates, so that no score has decayed yet.
        let store = try MailStore(writer: database, now: StoreTestClock().reading)
        #expect(try await store.correspondent("maya@example.com") == nil)

        #expect(try await store.performMaintenance(slice: 2) == true)
        #expect(try await store.performMaintenance(slice: 2) == false)

        #expect(try await store.missingAttachments(amongNewest: 10, maxSize: .max, limit: 10, skippingEmailsOnlyIn: [])
            == [AttachmentRef(blobId: "report", type: "application/pdf", name: "Report.pdf", size: 900)])
        let maya = try #require(try await store.correspondent("maya@example.com"))
        #expect(maya.receivedScore == 1 && maya.sentScore == 0)
        let jonas = try #require(try await store.correspondent("jonas@example.com"))
        #expect(jonas.sentScore == 1 && jonas.receivedScore == 0)
        #expect(try await store.correspondent("alex@example.com") == nil)

        // Done means done: neither more maintenance nor fetching the same mail again counts anything twice.
        try await store.maintainFully()
        try await store.upsert([StoreFixtures.email("e1", day: 1, keywords: ["$seen"])])
        #expect(try await store.correspondent("maya@example.com")?.receivedScore == 1)
    }

    @Test func mailStoredDuringTheBackfillIsCountedExactlyOnce() async throws {
        let clock = StoreTestClock(StoreFixtures.epoch.addingTimeInterval(10 * 86_400))
        let database = try await Self.v4Database(mailboxes: StoreFixtures.standardMailboxes, emails: [
            StoreFixtures.email("e1", day: 10, from: ["maya@example.com"]),
            StoreFixtures.email("e2", day: 10, from: ["nora@example.com"]),
        ])
        let store = try MailStore(writer: database, now: clock.reading)

        // The first upsert fixes the backfill's end at the mail stored so far.
        try await store.upsert([StoreFixtures.email("e3", day: 10, from: ["olaf@example.com"])])
        #expect(try await store.correspondent("olaf@example.com")?.receivedScore == 1)

        // Deleting the newest rows lets the next email reuse a rowid the backfill hasn't reached yet.
        try await store.deleteEmails(ids: ["e3", "e2"])
        try await store.upsert([StoreFixtures.email("e4", day: 10, from: ["pia@example.com"])])

        try await store.maintainFully(slice: 1)

        #expect(try await store.correspondent("maya@example.com")?.receivedScore == 1)
        #expect(try await store.correspondent("pia@example.com")?.receivedScore == 1)
        #expect(try await store.correspondent("olaf@example.com")?.receivedScore == 1)
        #expect(try await store.correspondent("nora@example.com") == nil)
    }
}
