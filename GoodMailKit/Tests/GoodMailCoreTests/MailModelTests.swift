import DemoAccount
import Foundation
import JMAPKit
import MailStore
import Testing
@testable import GoodMailCore

/// Runs the model against the in-memory demo account, which behaves like a small JMAP server.
@MainActor
struct MailModelTests {
    let server = DemoTransport()
    let store: MailStore
    let model: MailModel

    init() throws {
        store = try MailStore()
        model = Self.makeModel(server: server, store: store)
    }

    private static func makeModel(server: DemoTransport, store: MailStore) -> MailModel {
        MailModel(
            client: JMAPClient(token: "demo", transport: server, maxRetries: 0), store: store,
            syncsInBackground: false, onUnauthorized: {})
    }

    private func started() async -> MailModel {
        await model.start()
        await model.loadThreads()
        return model
    }

    private func unreadThreads(in role: Mailbox.Role) -> Int? {
        model.mailbox(role)?.unreadThreads
    }

    @Test func startSelectsInboxAndLoadsAccount() async {
        let model = await started()

        #expect(model.username == "alex@fastmail.com")
        #expect(model.currentMailbox?.role == .inbox)
        #expect(model.mailboxRows.map(\.mailbox.name).prefix(6) == ["Inbox", "Archive", "Drafts", "Sent", "Spam", "Trash"])
        #expect(model.mailboxRows.first { $0.mailbox.name == "Lisbon 2026" }?.depth == 1)
        #expect(model.maskedEmails.count == 6)
        #expect(model.errorMessage == nil)
    }

    @Test func listsInboxThreadsNewestFirstWithWholeConversations() async throws {
        let model = await started()

        #expect(model.threads.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"])
        #expect(model.totalThreads == 8)
        #expect(!model.hasMoreThreads)
        let trip = try #require(model.thread(id: "t1"))
        #expect(trip.emails.map(\.id) == ["e1", "e2", "e3"])
        #expect(trip.isUnread)
        #expect(trip.hasAttachment)
        #expect(unreadThreads(in: .inbox) == 2)
    }

    @Test func switchingMailboxReplacesTheListAndSelection() async {
        let model = await started()
        model.selectedThreadID = "t1"

        model.destination = .mailbox("sent")
        await model.loadThreads()

        #expect(model.threads.map(\.id) == ["t11", "t1"])
        #expect(model.selectedThreadID == nil)
    }

    @Test func searchesWithinMailboxOrEverywhereButNeverTrashAndSpam() async {
        let model = await started()

        model.searchText = "dispossessed"
        await model.loadThreads(debounce: false)
        #expect(model.threads.map(\.id) == ["t7"])

        model.searchScope = .everywhere
        await model.loadThreads(debounce: false)
        #expect(model.threads.map(\.id) == ["t7", "t10"])

        model.searchText = "selected"
        await model.loadThreads(debounce: false)
        #expect(model.threads.isEmpty)
    }

    @Test func unreadFilterShowsOnlyUnreadConversations() async {
        let model = await started()
        model.showsUnreadOnly = true
        await model.loadThreads()
        #expect(model.threads.map(\.id) == ["t1", "t2"])
    }

    @Test func markingReadUpdatesListAndMailboxCounts() async throws {
        let model = await started()

        await model.setRead(true, threadID: "t1")
        #expect(model.thread(id: "t1")?.isUnread == false)
        #expect(unreadThreads(in: .inbox) == 1)

        await model.setRead(false, threadID: "t1")
        let trip = try #require(model.thread(id: "t1"))
        #expect(trip.emails.filter { !$0.has(.seen) }.map(\.id) == ["e3"])
        #expect(unreadThreads(in: .inbox) == 2)
    }

    @Test func flagTogglesOnNewestMessageAndClearsWholeThread() async {
        let model = await started()

        await model.toggleFlag(threadID: "t1")
        #expect(model.thread(id: "t1")?.emails.filter { $0.has(.flagged) }.map(\.id) == ["e3"])
        await model.toggleFlag(threadID: "t1")
        #expect(model.thread(id: "t1")?.isFlagged == false)
    }

    @Test func archivingRemovesThreadSelectsNeighbourAndKeepsSentCopies() async {
        let model = await started()
        model.selectedThreadID = "t1"

        await model.archive(threadID: "t1")

        #expect(model.threads.map(\.id).first == "t2")
        #expect(model.selectedThreadID == "t2")
        #expect(model.totalThreads == 7)

        model.destination = .mailbox("archive")
        await model.loadThreads()
        #expect(model.thread(id: "t1")?.emails.map { $0.mailboxIds ?? [:] }
            == [["archive": true], ["sent": true], ["archive": true]])
        #expect(!model.canArchive)
    }

    @Test func trashingMovesEveryMessageOfTheThread() async {
        let model = await started()

        await model.trash(threadID: "t1")
        #expect(model.thread(id: "t1") == nil)

        model.destination = .mailbox("trash")
        await model.loadThreads()
        #expect(model.thread(id: "t1")?.emails.allSatisfy { $0.mailboxIds == ["trash": true] } == true)
        #expect(!model.canTrash)
    }

    @Test func movingToAnotherMailbox() async {
        let model = await started()

        await model.move(threadID: "t3", to: "receipts")

        #expect(model.thread(id: "t3") == nil)
        #expect(model.mailbox(id: "receipts")?.totalEmails == 2)
    }

    @Test func recognisesMailDeliveredToMaskedAddresses() async throws {
        let model = await started()
        let newsletter = try #require(model.thread(id: "t2")?.anchor)
        let personal = try #require(model.thread(id: "t1")?.anchor)

        #expect(model.maskedEmail(for: newsletter)?.description == "Fjord Outdoor newsletter")
        #expect(model.maskedEmail(for: personal) == nil)
    }

    @Test func managesMaskedEmails() async throws {
        let model = await started()

        await model.setMaskedEmailState(.disabled, id: "masked-1")
        #expect(model.maskedEmails.first { $0.id == "masked-1" }?.state == .disabled)

        await model.setMaskedEmailDescription("Outdoor shop", id: "masked-1")
        #expect(model.maskedEmails.first { $0.id == "masked-1" }?.description == "Outdoor shop")

        let created = try await model.createMaskedEmail(.init(description: "Test shop", emailPrefix: "shop"))
        #expect(created.email.hasPrefix("shop."))
        #expect(model.maskedEmails.contains { $0.id == created.id && $0.description == "Test shop" })
    }

    @Test func showMailToAddressSearchesEverywhere() async {
        let model = await started()
        model.destination = .maskedEmail

        model.showMail(to: "parcel.q8w1@fastmail.com")
        await model.loadThreads(debounce: false)

        #expect(model.currentMailbox?.role == .inbox)
        #expect(model.threads.map(\.id) == ["t6"])
    }

    // MARK: Stored mail

    @Test func nextLaunchWorksOfflineFromTheStore() async throws {
        let model = await started()
        _ = try await model.fetchEmails(inThread: "t1")

        server.isOffline = true
        let relaunched = Self.makeModel(server: server, store: store)
        await relaunched.start()
        await relaunched.loadThreads()

        #expect(relaunched.currentMailbox?.role == .inbox)
        #expect(relaunched.threads.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"])
        #expect(relaunched.totalThreads == 8)
        #expect(relaunched.connectionProblem != nil)
        #expect(relaunched.errorMessage == nil)
        #expect(await relaunched.storedEmails(inThread: "t1")?.map(\.id) == ["e1", "e2", "e3"])
        #expect(await relaunched.storedEmails(inThread: "t2") == nil)

        server.isOffline = false
        await relaunched.refresh()
        #expect(relaunched.connectionProblem == nil)
    }

    @Test func refreshBringsInNewMail() async {
        let model = await started()

        server.deliver(id: "new1", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        await model.refresh()

        #expect(model.threads.first?.id == "tNew")
        #expect(model.threads.first?.isUnread == true)
        #expect(unreadThreads(in: .inbox) == 3)
    }

    @Test func storedMailIsSearchedBeforeAndWithoutTheServer() async throws {
        let model = await started()
        while try await MailSync(client: model.client, store: store).backfillNextPage() {}
        server.isOffline = true

        model.searchScope = .everywhere
        model.searchText = "apartment view"
        await model.loadThreads(debounce: false)

        #expect(model.threads.map(\.id) == ["t9"])
    }

    @Test func conversationStaysInUnreadListWhileBeingRead() async {
        let model = await started()
        model.showsUnreadOnly = true
        await model.loadThreads()
        model.selectedThreadID = "t1"

        await model.setRead(true, threadID: "t1")

        #expect(model.threads.map(\.id) == ["t1", "t2"])
        #expect(model.selectedThreadID == "t1")

        await model.trash(threadID: "t1")
        #expect(model.threads.map(\.id) == ["t2"])
        #expect(model.selectedThreadID == "t2")
    }

    @Test func failedTriageIsReportedAndUndone() async {
        let model = await started()
        server.isOffline = true

        await model.archive(threadID: "t1")

        #expect(model.errorMessage != nil)
        #expect(model.threads.map(\.id).first == "t1")
        #expect(model.thread(id: "t1")?.emails.first?.mailboxIds == ["inbox": true])
    }
}
