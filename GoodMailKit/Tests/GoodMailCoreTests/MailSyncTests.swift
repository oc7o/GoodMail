import DemoAccount
import Foundation
import JMAPKit
import MailStore
import Testing
@testable import GoodMailCore

struct MailSyncTests {
    let server = DemoTransport()
    let store = try! MailStore()
    var client: JMAPClient { JMAPClient(token: "demo", transport: server, maxRetries: 0) }
    var sync: MailSync { MailSync(client: client, store: store) }

    private func inbox(position: Int, limit: Int) async throws -> ThreadPage {
        try await sync.fetchThreads(
            matching: .condition(.init(inMailbox: "inbox")), position: position, limit: limit,
            extendingCoverageOf: "inbox")
    }

    private func storedInbox() async throws -> [String] {
        guard let coverage = try await store.coverage(mailboxID: "inbox") else { return [] }
        return try await store.threads(matching: .init(mailboxID: "inbox", since: coverage), limit: 50).map(\.id)
    }

    @Test func pagesExtendCoverageOnlyWhenTheyConnect() async throws {
        #expect(try await storedInbox() == [])

        let first = try await inbox(position: 0, limit: 3)
        #expect(try await storedInbox() == ["t1", "t2", "t3"])
        #expect(try await store.coverage(mailboxID: "inbox") == first.threads.last?.anchor?.receivedAt)
        #expect(try await store.emailState() == first.state)

        // Skipping ahead leaves a gap, so those threads are stored but not listed yet.
        _ = try await inbox(position: 6, limit: 2)
        #expect(try await storedInbox() == ["t1", "t2", "t3"])

        _ = try await inbox(position: 3, limit: 3)
        #expect(try await storedInbox() == ["t1", "t2", "t3", "t4", "t5", "t6"])

        _ = try await inbox(position: 6, limit: 3)
        #expect(try await storedInbox() == ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"])
        #expect(try await store.coverage(mailboxID: "inbox") == .distantPast)
    }

    @Test func searchPagesAreStoredWithoutClaimingCoverage() async throws {
        _ = try await sync.fetchThreads(matching: .condition(.init(text: "dispossessed")), position: 0, limit: 10)
        #expect(try await store.threads(ids: ["t7", "t10"]).count == 2)
        #expect(try await store.coverage(mailboxID: "inbox") == nil)
    }

    @Test func syncAppliesNewChangedAndDeletedMail() async throws {
        _ = try await inbox(position: 0, limit: 50)
        #expect(try await sync.syncChanges() == .unchanged)

        server.deliver(id: "new1", threadId: "t1", from: "Maya", subject: "Re: Trip to Lisbon", text: "One more thing")
        server.deliver(id: "new2", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        server.destroyEmail(id: "e11")
        try await client.updateEmails(["e6": .move(from: "inbox", to: "archive"), "e5": .setKeyword(.flagged, true)])

        #expect(try await sync.syncChanges() == .changed)

        // The two new messages arrive within the same second, so their relative order is not defined.
        let listed = try await storedInbox()
        #expect(Set(listed.prefix(2)) == ["tNew", "t1"])
        #expect(listed.dropFirst(2) == ["t2", "t3", "t5", "t6", "t7"])
        let threads = try await store.threads(ids: ["t1", "t3", "t4"])
        #expect(threads.first { $0.id == "t1" }?.emails.map(\.id) == ["e1", "e2", "e3", "new1"])
        #expect(threads.first { $0.id == "t3" }?.isFlagged == true)
        #expect(threads.first { $0.id == "t4" }?.emails.first?.mailboxIds == ["archive": true])
        #expect(try await sync.syncChanges() == .unchanged)
    }

    @Test func syncStartsOverWhenTheServerForgotItsHistory() async throws {
        _ = try await inbox(position: 0, limit: 50)
        server.deliver(id: "new1", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        server.forgetChangeHistory()

        #expect(try await sync.syncChanges() == .reset)
        #expect(try await store.emailState() == nil)
        #expect(try await store.threads(ids: ["t1"]).isEmpty)
        #expect(try await storedInbox() == [])
    }

    @Test func syncDoesNothingBeforeTheFirstFetch() async throws {
        #expect(try await sync.syncChanges() == .unchanged)
    }

    @Test func backfillStoresTheWholeAccountInSlices() async throws {
        var pages = 0
        while try await sync.backfillNextPage(limit: 5) { pages += 1 }

        #expect(pages >= 3)
        #expect(try await store.backfillCursor() == .distantPast)
        #expect(try await store.threads(matching: .init(), limit: 50).count == 14)
        // Every mailbox is now covered without ever having been opened.
        #expect(try await store.threads(matching: .init(mailboxID: "archive", since: .distantPast), limit: 5).map(\.id) == ["t9"])
        #expect(try await store.coverage(mailboxID: "archive") == .distantPast)
        #expect(try await sync.backfillNextPage(limit: 5) == false)
        #expect(try await sync.syncChanges() == .unchanged)
    }

    @Test func prefetchMakesRecentConversationsReadableOffline() async throws {
        _ = try await inbox(position: 0, limit: 50)
        #expect(try await store.emailsWithBodies(inThread: "t1") == nil)

        var stored = 0
        while case let count = try await sync.prefetchBodies(limit: 4), count > 0 { stored += count }

        #expect(stored == 11)
        server.isOffline = true
        let emails = try #require(try await store.emailsWithBodies(inThread: "t1"))
        #expect(emails.map(\.id) == ["e1", "e2", "e3"])
        #expect(emails[2].bodyValues?["1"]?.value.contains("Booked!") == true)
        #expect(try await store.threads(matching: .init(search: SearchQuery(parsing: "early check-in")), limit: 5).map(\.id) == ["t1"])
    }

    @Test func refusedChangesAreRolledBack() async throws {
        _ = try await inbox(position: 0, limit: 50)
        let updates: [String: PatchObject] = ["e4": .moveExclusively(to: "trash")]

        let originals = try await sync.stage(updates)
        #expect(try await storedInbox().contains("t2") == false)

        server.isOffline = true
        await #expect(throws: (any Error).self) { try await sync.commit(updates, reverting: originals) }
        #expect(try await storedInbox().contains("t2"))
    }
}
