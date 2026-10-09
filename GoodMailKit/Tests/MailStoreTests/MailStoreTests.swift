import Foundation
import GRDB
import JMAPKit
import Testing
@testable import MailStore

struct MailStoreTests {
    let store = try! MailStore()
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    /// An email received `day` days after a fixed date, optionally with a fetched body.
    static func email(
        _ id: String, thread: String, in mailboxes: [String] = ["inbox"], day: Double, seen: Bool = true,
        flagged: Bool = false, subject: String = "Hello", from: String = "Maya Lindqvist", to: String = "Alex Berg",
        preview: String = "", hasAttachment: Bool = false, html: String? = nil
    ) -> Email {
        func address(_ name: String) -> [[String: String]] {
            [["name": name, "email": "\(name.split(separator: " ")[0].lowercased())@example.com"]]
        }
        var keywords: [String: Bool] = [:]
        if seen { keywords["$seen"] = true }
        if flagged { keywords["$flagged"] = true }
        var json: [String: Any] = [
            "id": id, "threadId": thread, "receivedAt": epoch.addingTimeInterval(day * 86_400).formatted(.iso8601),
            "mailboxIds": Dictionary(uniqueKeysWithValues: mailboxes.map { ($0, true) }),
            "keywords": keywords, "subject": subject, "preview": preview, "hasAttachment": hasAttachment,
            "from": address(from), "to": address(to),
        ]
        if let html {
            json["htmlBody"] = [["partId": "1", "type": "text/html"]]
            json["bodyValues"] = ["1": ["value": html, "isEncodingProblem": false, "isTruncated": false]]
        }
        return try! JMAPCoding.makeDecoder().decode(Email.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func threadIDs(_ query: MailStore.ThreadQuery, limit: Int = 50) async throws -> [String] {
        try await store.threads(matching: query, limit: limit).map(\.id)
    }

    @Test func databaseFileIsEncryptedAndNeedsItsKey() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)/Mail.sqlite")
        defer { MailStore.destroy(at: url) }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        do {
            let store = try MailStore(url: url) { key }
            try await store.upsert([Self.email("e1", thread: "t1", day: 1, subject: "TOPSECRETSUBJECT")])
        }

        let raw = try Data(contentsOf: url) + ((try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))) ?? Data())
        #expect(raw.range(of: Data("TOPSECRETSUBJECT".utf8)) == nil)
        #expect(raw.range(of: Data("SQLite format 3".utf8)) == nil)

        #expect(throws: (any Error).self) { try MailStore(url: url) { Data(repeating: 7, count: 32) } }
        let reopened = try MailStore(url: url) { key }
        #expect(try await reopened.emails(ids: ["e1"]).first?.subject == "TOPSECRETSUBJECT")
    }

    @Test func mailboxesKeepTheirOrder() async throws {
        let mailboxes = try JSONDecoder().decode([Mailbox].self, from: Data("""
            [{"id": "b", "name": "Inbox", "role": "inbox", "sortOrder": 1, "totalEmails": 3, "unreadEmails": 1,
              "totalThreads": 2, "unreadThreads": 1, "isSubscribed": true},
             {"id": "a", "name": "Work", "parentId": "b", "sortOrder": 2, "totalEmails": 0, "unreadEmails": 0,
              "totalThreads": 0, "unreadThreads": 0, "isSubscribed": true}]
            """.utf8))

        try await store.replaceMailboxes(mailboxes)
        #expect(try await store.mailboxes() == mailboxes)

        try await store.replaceMailboxes([mailboxes[1]])
        #expect(try await store.mailboxes().map(\.id) == ["a"])
    }

    @Test func listsThreadsOfAMailboxNewestFirstWithAllTheirEmails() async throws {
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1),
            Self.email("e2", thread: "t1", in: ["sent"], day: 2),
            Self.email("e3", thread: "t1", day: 5, seen: false),
            Self.email("e4", thread: "t2", day: 4),
            Self.email("e5", thread: "t3", in: ["archive"], day: 9),
        ])

        let threads = try await store.threads(matching: .init(mailboxID: "inbox"), limit: 50)

        #expect(threads.map(\.id) == ["t1", "t2"])
        #expect(threads[0].emails.map(\.id) == ["e1", "e2", "e3"])
        #expect(threads[0].anchorId == "e3")
        #expect(try await threadIDs(.init(mailboxID: "sent")) == ["t1"])
        #expect(try await store.threads(matching: .init(mailboxID: "sent"), limit: 50).first?.anchorId == "e2")
        #expect(try await threadIDs(.init(mailboxID: "inbox"), limit: 1) == ["t1"])
        #expect(try await store.threadCount(matching: .init(mailboxID: "inbox")) == 2)
    }

    @Test func coverageBoundHidesOlderThreads() async throws {
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1), Self.email("e2", thread: "t2", day: 5),
            Self.email("e3", thread: "t3", day: 9),
        ])
        let since = Self.epoch.addingTimeInterval(5 * 86_400)
        #expect(try await threadIDs(.init(mailboxID: "inbox", since: since)) == ["t3", "t2"])
    }

    @Test func filtersUnreadAndHiddenMailboxes() async throws {
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1, seen: false),
            Self.email("e2", thread: "t2", day: 2),
            Self.email("e3", thread: "t3", in: ["trash"], day: 3, seen: false),
            Self.email("e4", thread: "t4", in: ["trash", "archive"], day: 4, seen: false),
        ])

        #expect(try await threadIDs(.init(mailboxID: "inbox", unreadOnly: true)) == ["t1"])
        #expect(try await threadIDs(.init(hiddenMailboxIDs: ["trash", "junk"], unreadOnly: true)) == ["t4", "t1"])
    }

    @Test func searchesSubjectPeoplePreviewAndFetchedBodies() async throws {
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1, subject: "Trip to Lisbon", preview: "I found flights"),
            Self.email("e2", thread: "t2", day: 2, subject: "Invoice", from: "Northwind Hosting"),
            Self.email("e3", thread: "t3", in: ["archive"], day: 3, subject: "Café menu"),
        ])

        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "lisb"))) == ["t1"])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "flights trip"))) == ["t1"])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "northwind"))) == ["t2"])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "cafe"))) == ["t3"])
        #expect(try await threadIDs(.init(mailboxID: "inbox", search: SearchQuery(parsing: "cafe"))) == [])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "\"*"))) == [])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "apartment"))) == [])

        try await store.upsert([Self.email(
            "e1", thread: "t1", day: 1, subject: "Trip to Lisbon",
            html: "<style>p { color: apartmentcolor }</style><p>The <b>apartment</b> in Alfama is free &amp; cheap</p>")])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "apartment alfama"))) == ["t1"])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "apartmentcolor"))) == [])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "lisbon"))) == ["t1"])
    }

    @Test func searchOperatorsLookAtTheirOwnFieldsAndFlags() async throws {
        let day = { (n: Double) in Self.epoch.addingTimeInterval(n * 86_400) }
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1, subject: "Notes for Maya", from: "Jonas Weber", to: "Maya Lindqvist"),
            Self.email("e2", thread: "t2", day: 2, flagged: true, subject: "Lisbon", from: "Maya Lindqvist"),
            Self.email("e3", thread: "t3", day: 3, subject: "Invoice", from: "Northwind Hosting", hasAttachment: true),
        ])
        func ids(_ search: String) async throws -> [String] {
            try await threadIDs(.init(search: SearchQuery(parsing: search)))
        }

        #expect(try await ids("maya") == ["t2", "t1"])
        #expect(try await ids("from:maya") == ["t2"])
        #expect(try await ids("to:maya") == ["t1"])
        #expect(try await ids("subject:maya") == ["t1"])
        #expect(try await ids("from:maya subject:invoice") == [])
        #expect(try await ids("is:flagged") == ["t2"])
        #expect(try await ids("has:attachment") == ["t3"])
        #expect(try await ids("is:unread") == [])

        var window = SearchQuery()
        window.after = day(2)
        window.before = day(3)
        #expect(try await threadIDs(.init(search: window)) == ["t2"])
        #expect(try await threadIDs(.init(search: window, since: day(2.5))) == [])
    }

    @Test func upgradingReindexesStoredMailForSearchOperators() async throws {
        let database = try DatabaseQueue()
        try MailStore.migrator.migrate(database, upTo: "v1")
        let email = Self.email("e1", thread: "t1", day: 1, flagged: true, from: "Maya Lindqvist", hasAttachment: true)
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO email (id, threadId, receivedAt, isSeen, json) VALUES ('e1', 't1', ?, 1, ?)",
                arguments: [email.receivedAt!.timeIntervalSince1970, try JMAPCoding.makeEncoder().encode(email)])
        }

        let store = try MailStore(writer: database)

        let search = SearchQuery(parsing: "from:maya is:flagged has:attachment")
        #expect(try await store.threads(matching: .init(search: search), limit: 5).map(\.id) == ["t1"])
        #expect(try await store.threads(matching: .init(search: SearchQuery(parsing: "to:maya")), limit: 5).isEmpty)
    }

    @Test func savedSearchesKeepTheirOrderThroughEdits() async throws {
        let unread = SavedSearch(name: "Unread", query: "is:unread", mailboxID: "inbox")
        var maya = SavedSearch(name: "Maya", query: "from:maya")
        try await store.save(unread)
        try await store.save(maya)

        maya.name = "Maya L."
        try await store.save(maya)
        #expect(try await store.savedSearches() == [unread, maya])

        try await store.deleteSavedSearch(id: unread.id)
        #expect(try await store.savedSearches() == [maya])
    }

    @Test func refreshingFlagsKeepsTheStoredBodyAndItsSearchText() async throws {
        try await store.upsert([Self.email("e1", thread: "t1", day: 1, seen: false, html: "<p>Quarterly numbers</p>")])
        #expect(try await store.emailsWithBodies(inThread: "t1")?.first?.has(.seen) == false)

        try await store.upsert([Self.email("e1", thread: "t1", in: ["archive"], day: 1, seen: true)])

        let email = try #require(try await store.emailsWithBodies(inThread: "t1")?.first)
        #expect(email.has(.seen))
        #expect(email.mailboxIds == ["archive": true])
        #expect(email.bodyValues?["1"]?.value == "<p>Quarterly numbers</p>")
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "quarterly"))) == ["t1"])
        #expect(try await threadIDs(.init(mailboxID: "inbox")) == [])
        #expect(try await threadIDs(.init(mailboxID: "archive")) == ["t1"])
    }

    @Test func threadBodiesAreOnlyReturnedWhenComplete() async throws {
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1, html: "<p>One</p>"), Self.email("e2", thread: "t1", day: 2),
        ])
        #expect(try await store.emailsWithBodies(inThread: "t1") == nil)
        #expect(try await store.emailsWithBodies(inThread: "missing") == nil)
        #expect(try await store.emailIDsMissingBody(amongNewest: 10, limit: 10) == ["e2"])

        try await store.upsert([Self.email("e2", thread: "t1", day: 2, html: "<p>Two</p>")])
        #expect(try await store.emailsWithBodies(inThread: "t1")?.map(\.id) == ["e1", "e2"])
        #expect(try await store.emailIDsMissingBody(amongNewest: 10, limit: 10) == [])
    }

    @Test func deletedEmailsDisappearFromListsAndSearch() async throws {
        try await store.upsert([
            Self.email("e1", thread: "t1", day: 1, subject: "Receipt"), Self.email("e2", thread: "t1", day: 2),
        ])

        try await store.deleteEmails(ids: ["e1"])

        #expect(try await store.threads(matching: .init(mailboxID: "inbox"), limit: 5).first?.emails.map(\.id) == ["e2"])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "receipt"))) == [])
        #expect(try await store.threads(ids: ["t1", "gone"]).map(\.id) == ["t1"])
    }

    @Test func coverageOnlyGrowsAndCombinesMailboxWithAccount() async throws {
        let day = { (n: Double) in Self.epoch.addingTimeInterval(n * 86_400) }
        #expect(try await store.coverage(mailboxID: "inbox") == nil)

        try await store.extendCoverage(mailboxID: "inbox", to: day(5))
        try await store.extendCoverage(mailboxID: "inbox", to: day(8))
        #expect(try await store.coverage(mailboxID: "inbox") == day(5))
        #expect(try await store.coverage(mailboxID: "archive") == nil)

        try await store.extendCoverage(mailboxID: nil, to: day(3))
        #expect(try await store.coverage(mailboxID: "inbox") == day(3))
        #expect(try await store.coverage(mailboxID: "archive") == day(3))
        #expect(try await store.backfillCursor() == day(3))
    }

    @Test func resetForgetsEmailsAndProgressButKeepsNothingSearchable() async throws {
        try await store.upsert([Self.email("e1", thread: "t1", day: 1, subject: "Receipt")])
        try await store.setEmailState("s1")
        try await store.extendCoverage(mailboxID: "inbox", to: Self.epoch)

        try await store.resetEmails()

        #expect(try await store.emailState() == nil)
        #expect(try await store.coverage(mailboxID: "inbox") == nil)
        #expect(try await threadIDs(.init(mailboxID: "inbox")) == [])
        #expect(try await threadIDs(.init(search: SearchQuery(parsing: "receipt"))) == [])
    }
}
