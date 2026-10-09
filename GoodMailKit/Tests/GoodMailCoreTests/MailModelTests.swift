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

    @Test func maskedEmailsShowOfflineFromTheStore() async {
        _ = await started()
        server.isOffline = true

        let relaunched = Self.makeModel(server: server, store: store)
        await relaunched.start()

        #expect(relaunched.maskedEmails.count == 6)
        #expect(relaunched.connectionProblem != nil)
    }

    // MARK: Stored mail

    @Test func inlineImagesAreDownloadedOnceAndShownOffline() async throws {
        let model = await started()
        let invoice = try #require(try await model.fetchEmails(inThread: "t3").first { $0.id == "e5" })

        let logo = await model.inlineImage(cid: "logo@northwind.example", in: invoice)
        #expect(logo?.type == "image/svg+xml")
        #expect(await model.inlineImage(cid: "unknown@northwind.example", in: invoice) == nil)

        server.isOffline = true
        #expect(await model.inlineImage(cid: "logo@northwind.example", in: invoice)?.data == logo?.data)
        #expect(server.downloadCount == 1)
    }

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

    @Test func searchOperatorsAskTheServerPrecisely() async {
        let model = await started()
        model.searchScope = .everywhere
        func search(_ text: String) async -> [String] {
            model.searchText = text
            await model.loadThreads(debounce: false)
            return model.threads.map(\.id)
        }

        #expect(await search("from:maya") == ["t1"])
        #expect(await search("to:lena") == ["t11"])
        #expect(await search("lena") == ["t11", "t9"])
        #expect(await search("is:flagged") == ["t4"])
        #expect(await search("from:maya has:attachment") == ["t1"])
        #expect(await search("in:archive") == ["t9"])
        #expect(await search("in:receipts corner") == ["t10"])
        #expect(await search("in:nowhere") == [])
        #expect(model.totalThreads == 0)
        #expect(model.connectionProblem == nil)
    }

    @Test func searchOperatorsWorkOnStoredMailOffline() async throws {
        let model = await started()
        while try await MailSync(client: model.client, store: store).backfillNextPage() {}
        server.isOffline = true
        model.searchScope = .everywhere
        func search(_ text: String) async -> [String] {
            model.searchText = text
            await model.loadThreads(debounce: false)
            return model.threads.map(\.id)
        }

        #expect(await search("to:lena") == ["t11"])
        #expect(await search("lena") == ["t11", "t9"])
        #expect(await search("is:flagged") == ["t4"])
        #expect(await search("from:maya has:attachment") == ["t1"])
        #expect(await search("in:archive") == ["t9"])
    }

    @Test func savedSearchListsRefinesAndSurvivesRelaunch() async throws {
        let model = await started()
        #expect(model.searchToSave == nil)
        model.searchScope = .everywhere
        model.searchText = "from:maya"

        let proposal = try #require(model.searchToSave)
        #expect(proposal.query == "from:maya")
        #expect(proposal.mailboxID == nil)
        await model.saveSearch(named: "Maya")

        let saved = try #require(model.savedSearches.first)
        #expect(model.destination == .savedSearch(saved.id))
        #expect(model.searchText.isEmpty)
        await model.loadThreads()
        #expect(model.threads.map(\.id) == ["t1"])

        model.searchText = "is:flagged"
        await model.loadThreads(debounce: false)
        #expect(model.threads.isEmpty)
        #expect(model.searchToSave?.query == "from:maya is:flagged")

        await model.renameSavedSearch(id: saved.id, to: "Maya L.")
        let relaunched = Self.makeModel(server: server, store: store)
        await relaunched.start()
        #expect(relaunched.savedSearches.map(\.name) == ["Maya L."])

        await model.deleteSavedSearch(id: saved.id)
        #expect(model.savedSearches.isEmpty)
        #expect(model.currentMailbox?.role == .inbox)
    }

    @Test func savingUnreadOnlyKeepsTheMailbox() async {
        let model = await started()
        model.showsUnreadOnly = true

        #expect(model.searchToSave?.query == "is:unread")
        #expect(model.searchToSave?.mailboxID == "inbox")
        await model.saveSearch(named: "Unread")
        #expect(!model.showsUnreadOnly)

        await model.loadThreads()
        #expect(model.threads.map(\.id) == ["t1", "t2"])
    }

    @Test func archivingFromAllMailTakesTheConversationOutOfItsFolder() async throws {
        let model = await started()
        model.searchScope = .everywhere
        model.searchText = "corner"
        await model.loadThreads(debounce: false)
        #expect(model.listedMailboxID == nil)

        await model.archive(threadID: "t10")

        #expect(model.errorMessage == nil)
        #expect(model.thread(id: "t10")?.emails.map(\.mailboxIds) == [["archive": true]])
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

    // MARK: Background work

    @Test func lowDataModeLeavesAttachmentsForLater() async throws {
        let account = try OutboxTestAccount()
        await account.start()
        account.network.set(NetworkPath(isSatisfied: true, isExpensive: true, isConstrained: true))
        for _ in 0..<1000 where account.model.networkPath?.isConstrained != true { await Task.yield() }

        while await account.model.performBackgroundWork() {}

        #expect(try await !account.store.isAttachmentCached(blobId: "e5-file0"))
        #expect(try await account.store.inlineImageData(blobId: "e5-logo") != nil)

        // Cellular without Low Data Mode is fine (D24).
        account.network.set(NetworkPath(isSatisfied: true, isExpensive: true))
        for _ in 0..<1000 where account.model.networkPath?.isConstrained != false { await Task.yield() }
        while await account.model.performBackgroundWork() {}

        #expect(try await account.store.isAttachmentCached(blobId: "e5-file0"))
        #expect(try await account.store.isAttachmentCached(blobId: "e3-file0"))
    }

    // MARK: Outbox

    private func serverEmail(_ id: String) async throws -> Email? {
        try await JMAPClient(token: "demo", transport: server, maxRetries: 0).emails(ids: [id]).first
    }

    @Test func triageOfflineWaitsInTheOutboxAcrossLaunches() async throws {
        let model = await started()
        server.isOffline = true

        await model.archive(threadID: "t2")

        #expect(model.thread(id: "t2") == nil)
        #expect(model.errorMessage == nil)
        #expect(model.connectionProblem != nil)
        #expect(model.pendingChangeCount == 1)

        let relaunched = Self.makeModel(server: server, store: store)
        await relaunched.start()
        await relaunched.loadThreads()
        #expect(relaunched.threads.map(\.id) == ["t1", "t3", "t4", "t5", "t6", "t7", "t8"])
        #expect(relaunched.pendingChangeCount == 1)

        server.isOffline = false
        await relaunched.refresh()
        #expect(relaunched.pendingChangeCount == 0)
        #expect(relaunched.connectionProblem == nil)
        #expect(relaunched.errorMessage == nil)
        #expect(relaunched.thread(id: "t2") == nil)
        #expect(try await serverEmail("e4")?.mailboxIds == ["archive": true])
    }

    @Test func sendingQueuedChangesAfterTheServerForgotItsHistoryReloadsTheList() async throws {
        let model = await started()
        server.isOffline = true
        await model.archive(threadID: "t2")
        server.deliver(id: "new1", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        server.forgetChangeHistory()

        server.isOffline = false
        await model.refresh()

        #expect(model.pendingChangeCount == 0)
        #expect(model.threads.map(\.id) == ["tNew", "t1", "t3", "t4", "t5", "t6", "t7", "t8"])
    }

    @Test func refusedTriageIsReportedAndUndone() async throws {
        let model = await started()
        server.rejectedEmailIDs = ["e4"]

        await model.archive(threadID: "t2")

        #expect(model.errorMessage == "Fastmail didn't accept a change to a message: Rejected by the demo server.")
        #expect(model.thread(id: "t2")?.emails.first?.mailboxIds == ["inbox": true])
        #expect(model.pendingChangeCount == 0)
        #expect(model.connectionProblem == nil)
    }

    @Test func changesMadeOfflineAreCoalescedIntoOneRequest() async throws {
        let model = await started()
        server.isOffline = true

        await model.toggleFlag(threadID: "t1")
        #expect(model.thread(id: "t1")?.isFlagged == true)
        await model.toggleFlag(threadID: "t1")
        #expect(model.thread(id: "t1")?.isFlagged == false)
        #expect(model.pendingChangeCount == 1)

        server.isOffline = false
        let requests = server.updateRequestCount
        await model.refresh()

        #expect(server.updateRequestCount == requests + 1)
        #expect(model.pendingChangeCount == 0)
        #expect(try await serverEmail("e3")?.has(.flagged) == false)
    }

    @Test func changesQueuedDuringAFlushAreSentByIt() async throws {
        let model = await started()

        async let archived: Void = model.archive(threadID: "t2")
        async let flagged: Void = model.toggleFlag(threadID: "t3")
        async let refreshed: Void = model.refresh()
        _ = await (archived, flagged, refreshed)

        #expect(model.pendingChangeCount == 0)
        #expect(try await serverEmail("e4")?.mailboxIds == ["archive": true])
        #expect(try await serverEmail("e5")?.has(.flagged) == true)
    }
}
