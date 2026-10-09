import DemoAccount
import Foundation
import JMAPKit
import MailStore
import Synchronization
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

    private func storedMailboxes(of id: String) async throws -> [String: Bool]? {
        try await store.emails(ids: [id]).first?.mailboxIds
    }

    private func serverEmail(_ id: String) async throws -> Email? {
        try await client.emails(ids: [id]).first
    }

    @Test func queuedChangesShowAtOnceAndAreSentLater() async throws {
        _ = try await inbox(position: 0, limit: 50)
        server.isOffline = true

        try await sync.enqueue(["e4": .moveExclusively(to: "trash"), "e5": .setKeyword(.seen, true)])
        #expect(try await storedInbox().contains("t2") == false)
        await #expect(throws: JMAPError.self) { try await sync.flushPendingChanges() }
        #expect(try await store.pendingEmailCount() == 2)
        #expect(try await storedMailboxes(of: "e4") == ["trash": true])

        server.isOffline = false
        #expect(try await sync.flushPendingChanges() == .init(sent: 2, rejected: [:]))
        #expect(try await store.pendingEmailCount() == 0)
        #expect(try await serverEmail("e4")?.mailboxIds == ["trash": true])
        #expect(try await serverEmail("e5")?.has(.seen) == true)
        #expect(try await sync.flushPendingChanges() == .init())
    }

    @Test func syncWhileAChangeIsQueuedDoesNotUndoIt() async throws {
        _ = try await inbox(position: 0, limit: 50)
        try await sync.enqueue(["e4": .move(from: "inbox", to: "archive")])
        // Another client flags the email, so the next sync brings in the server's copy, still in the inbox.
        try await client.updateEmails(["e4": .setKeyword(.flagged, true)])

        #expect(try await sync.syncChanges() == .changed)
        let stored = try #require(try await store.emails(ids: ["e4"]).first)
        #expect(stored.mailboxIds == ["archive": true])
        #expect(stored.has(.flagged))
        #expect(try await storedInbox().contains("t2") == false)

        _ = try await sync.flushPendingChanges()
        _ = try await sync.syncChanges()
        #expect(try await serverEmail("e4")?.mailboxIds == ["archive": true])
        #expect(try await storedMailboxes(of: "e4") == ["archive": true])
    }

    @Test func refusedChangesAreReplacedByTheServerCopy() async throws {
        _ = try await inbox(position: 0, limit: 50)
        server.rejectedEmailIDs = ["e4"]
        try await sync.enqueue(["e4": .moveExclusively(to: "trash"), "e5": .setKeyword(.flagged, true)])
        server.destroyEmail(id: "e6")
        try await sync.enqueue(["e6": .setKeyword(.seen, true)])

        let result = try await sync.flushPendingChanges()

        #expect(result.sent == 1)
        #expect(result.rejected.mapValues(\.type) == ["e4": "forbidden", "e6": SetError.notFound])
        #expect(try await store.pendingEmailCount() == 0)
        #expect(try await storedMailboxes(of: "e4") == ["inbox": true])
        #expect(try await storedInbox().contains("t2"))
        #expect(try await store.emails(ids: ["e6"]).isEmpty)
        #expect(try await serverEmail("e5")?.has(.flagged) == true)
    }

    @Test func refusedChangesStayQueuedUntilTheServerCopyArrives() async throws {
        let server = FaultyTransport()
        let client = JMAPClient(token: "demo", transport: server, maxRetries: 0)
        let sync = MailSync(client: client, store: store)
        _ = try await sync.fetchThreads(
            matching: .condition(.init(inMailbox: "inbox")), position: 0, limit: 50, extendingCoverageOf: "inbox")
        server.server.rejectedEmailIDs = ["e4"]
        try await sync.enqueue(["e4": .moveExclusively(to: "trash"), "e5": .setKeyword(.flagged, true)])
        server.fail("Email/get", with: .dropped)

        await #expect(throws: JMAPError.self) { try await sync.flushPendingChanges() }
        #expect(try await store.pendingChanges()?.updates.keys.sorted() == ["e4"])
        #expect(try await storedMailboxes(of: "e4") == ["trash": true])

        server.fail("Email/get", with: nil)
        let result = try await sync.flushPendingChanges()
        #expect(result.rejected.mapValues(\.type) == ["e4": "forbidden"])
        #expect(try await store.pendingEmailCount() == 0)
        #expect(try await storedMailboxes(of: "e4") == ["inbox": true])
        #expect(try await client.emails(ids: ["e5"]).first?.has(.flagged) == true)
    }

    @Test func changesTheServerCanNeverProcessAreDroppedAndUndone() async throws {
        let server = FaultyTransport()
        let sync = MailSync(client: JMAPClient(token: "demo", transport: server, maxRetries: 0), store: store)
        _ = try await sync.fetchThreads(
            matching: .condition(.init(inMailbox: "inbox")), position: 0, limit: 50, extendingCoverageOf: "inbox")
        try await sync.enqueue(["e4": .moveExclusively(to: "trash")])
        server.fail("Email/set", with: .status(400))
        server.fail("Email/get", with: .dropped)

        // Dropping the change now would leave it showing, so it waits until the server copy can replace it.
        await #expect(throws: JMAPError.self) { try await sync.flushPendingChanges() }
        #expect(try await store.pendingEmailCount() == 1)
        #expect(try await storedMailboxes(of: "e4") == ["trash": true])

        server.fail("Email/get", with: nil)
        await #expect(throws: JMAPError.http(status: 400, problemType: nil)) { try await sync.flushPendingChanges() }
        #expect(try await store.pendingEmailCount() == 0)
        #expect(try await storedMailboxes(of: "e4") == ["inbox": true])
    }

    @Test func changesWaitOutAnUnavailableServer() async throws {
        let server = FaultyTransport()
        let sync = MailSync(client: JMAPClient(token: "demo", transport: server, maxRetries: 0), store: store)
        _ = try await sync.fetchThreads(
            matching: .condition(.init(inMailbox: "inbox")), position: 0, limit: 50, extendingCoverageOf: "inbox")
        try await sync.enqueue(["e4": .moveExclusively(to: "trash")])
        server.fail("Email/set", with: .methodError(MethodError.serverUnavailable))

        await #expect(throws: JMAPError.self) { try await sync.flushPendingChanges() }
        #expect(try await store.pendingEmailCount() == 1)
        #expect(try await storedMailboxes(of: "e4") == ["trash": true])

        server.fail("Email/set", with: nil)
        #expect(try await sync.flushPendingChanges() == .init(sent: 1, rejected: [:]))
    }

    @Test func onlyRequestsThatCanNeverSucceedDiscardChanges() throws {
        func method(_ type: String) throws -> JMAPError {
            .method(try JSONDecoder().decode(MethodError.self, from: Data(#"{"type": "\#(type)"}"#.utf8)))
        }
        #expect(MailSync.discardsChanges(after: JMAPError.http(status: 400, problemType: nil)))
        #expect(MailSync.discardsChanges(after: try method("invalidArguments")))
        #expect(!MailSync.discardsChanges(after: JMAPError.transport("offline")))
        #expect(!MailSync.discardsChanges(after: JMAPError.http(status: 503, problemType: nil)))
        #expect(!MailSync.discardsChanges(after: JMAPError.http(status: 400, problemType: JMAPError.limitProblemType)))
        #expect(!MailSync.discardsChanges(after: try method(MethodError.serverUnavailable)))
        #expect(!MailSync.discardsChanges(after: JMAPError.unauthorized))
        #expect(!MailSync.discardsChanges(after: CancellationError()))
    }
}

/// The demo server, except that calls to chosen methods can be made to fail.
private final class FaultyTransport: HTTPTransport {
    enum Fault {
        case status(Int)
        case methodError(String)
        case dropped
    }

    let server = DemoTransport()
    private let faults = Mutex<[String: Fault]>([:])

    func fail(_ method: String, with fault: Fault?) {
        faults.withLock { $0[method] = fault }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody ?? Data()
        let calls = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["methodCalls"] as? [[Any]] ?? []
        guard let call = calls.first, let fault = faults.withLock({ $0[call[0] as? String ?? ""] }) else {
            return try await server.send(request)
        }
        switch fault {
        case .status(let status):
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .methodError(let type):
            let response: [String: Any] = ["sessionState": "demo", "methodResponses": [["error", ["type": type], call[2]]]]
            return (
                try JSONSerialization.data(withJSONObject: response),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .dropped:
            throw URLError(.notConnectedToInternet)
        }
    }
}
