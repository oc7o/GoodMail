import DemoAccount
import Foundation
import JMAPKit
import MailCompose
import MailStore
import Testing
@testable import GoodMailCore

/// Drafts kept in step with Fastmail's Drafts alongside other devices (§2.3, D10, D32, C5, C14, C28): saves
/// whose answers went missing, versions saved elsewhere, drafts deleted or sent elsewhere, uploads.
@MainActor
struct DraftSyncTests {
    let account: OutboxTestAccount
    var model: MailModel { account.model }
    var outbox: Outbox { account.outbox }
    var server: DemoTransport { account.server }
    let maya = EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")

    init() throws {
        account = try OutboxTestAccount()
    }

    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0..<50_000 {
            if try await condition() { return true }
            await Task.yield()
        }
        return try await condition()
    }

    /// A message to Maya saved to Drafts, with the refresh and outbox pass that saving starts finished;
    /// returns the composer and its server copy.
    private func savedDraft() async throws -> (Composer, String) {
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        await model.refresh()
        await account.settle()
        return (composer, try #require(try await account.row(composer.id)?.serverEmailID))
    }

    // MARK: Own saves (C5)

    @Test func aCloseSaveRacingSendRaisesNoConflict() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let draft = composer.draft
        account.transport.hold("Email/set")

        await composer.close()
        #expect(await eventually { account.transport.heldRequests == 1 })
        try await outbox.send(draft)
        account.transport.release("Email/set")
        await account.settle()

        let row = try #require(try await account.row(composer.id))
        #expect(row.state == .held)
        #expect(row.record.notice == nil && outbox.notices.isEmpty)
        let copies = try await account.copies(of: row.messageID)
        #expect(copies.count == 1 && copies.values.first == ["sent": true])
    }

    @Test func aCopyMadeByASaveWhoseAnswerWasLostIsCleanedUp() async throws {
        await account.start()
        let (composer, first) = try await savedDraft()
        server.advanceClock(by: 2)
        composer.body = AttributedString("Make it one")
        account.transport.beforeNext("Email/set") { [server] in server.loseNextResponse() }

        await composer.saveNow()

        #expect(composer.saveStatus == .savedLocally)
        #expect(try await account.row(composer.id)?.serverEmailID == first)
        #expect(try await account.record(composer.id)?.lastAttempt != nil)
        #expect(try await account.serverEmail(first) == nil)

        server.advanceClock(by: 2)
        composer.body = AttributedString("Make it half past")
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        let current = try #require(row.serverEmailID)
        #expect(try await account.copies(of: row.messageID) == [current: ["drafts": true]])
        #expect(composer.notices.isEmpty && row.record.notice == nil && row.record.lastAttempt == nil)
        #expect(composer.saveStatus == .savedToServer(account.clock.now))
    }

    @Test func aCopyMadeByAnAutomaticRetryIsAStrayNotAConflict() async throws {
        let account = try OutboxTestAccount(maxRetries: 1)
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        await account.model.refresh()
        await account.settle()
        let creates = account.transport.arguments(of: "Email/set").filter(\.creates).count
        account.server.advanceClock(by: 2)
        composer.body = AttributedString("Make it one")
        // The server saves, then answers 503; the client sends the save again, which finds the previous copy gone.
        account.transport.beforeNext("Email/set") { [server = account.server] in server.answerNext(withStatus: 503) }

        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        #expect(try await account.copies(of: row.messageID) == [try #require(row.serverEmailID): ["drafts": true]])
        #expect(composer.notices.isEmpty && row.record.notice == nil)
        // The save answered with 503 and its retry; the stray's destruction creates nothing.
        #expect(account.transport.arguments(of: "Email/set").filter(\.creates).count == creates + 2)
    }

    /// A saved draft, then a save whose answer is lost: its copy replaced the first one on the server.
    private func draftWithALostSave() async throws -> (Composer, messageID: String) {
        let (composer, first) = try await savedDraft()
        server.advanceClock(by: 2)
        composer.body = AttributedString("Make it one")
        account.transport.beforeNext("Email/set") { [server] in server.loseNextResponse() }
        await composer.saveNow()
        let messageID = composer.draft.messageID
        #expect(try await account.serverEmail(first) == nil)
        #expect(try await account.copies(of: messageID).count == 1)
        return (composer, messageID)
    }

    @Test func theCopyOfASaveWhoseAnswerWasLostGoesOnceTheMessageIsSent() async throws {
        await account.start()
        let (composer, messageID) = try await draftWithALostSave()

        try await composer.send()
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .held)
        await account.advance(17)

        #expect(try await account.row(composer.id) == nil)
        #expect(server.sentMessages.map(\.messageId) == [messageID])
        #expect(try await account.copies(of: messageID).values.map { $0 } == [["sent": true]])
    }

    @Test func theCopyOfASaveWhoseAnswerWasLostStaysOwnAfterASubmitThatNeverLeft() async throws {
        await account.start()
        let (composer, messageID) = try await draftWithALostSave()
        account.transport.failNext("EmailSubmission/set", with: .notConnectedToInternet)

        try await composer.send()
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .queued)
        await account.advance(30)

        // Still this composition's own copy, not another device's version to fork from.
        let row = try #require(try await account.row(composer.id))
        #expect(row.state == .held && row.messageID == messageID && row.record.notice == nil)
        await account.advance(17)
        #expect(server.sentMessages.map(\.messageId) == [messageID])
        #expect(try await account.copies(of: messageID).values.map { $0 } == [["sent": true]])
    }

    @Test func theCopyOfASaveWhoseAnswerWasLostStaysOwnAfterASendThatFailedBeforeAsking() async throws {
        await account.start()
        let (composer, messageID) = try await draftWithALostSave()
        // From an address that is none of the user's: it fails before anything is asked of Fastmail.
        var draft = composer.draft
        draft.from = EmailAddress(email: "nobody@fastmail.com")
        try await outbox.send(draft)
        await account.settle()
        #expect(outbox.items.map(\.state) == [.failed(.senderNotAllowed("nobody@fastmail.com"))])

        server.advanceClock(by: 2)
        composer.body = AttributedString("Make it half past")
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        let current = try #require(row.serverEmailID)
        #expect(row.state == .editing && row.messageID == messageID)
        #expect(row.record.notice == nil && composer.notices.isEmpty)
        #expect(try await account.copies(of: messageID) == [current: ["drafts": true]])
    }

    @Test func copiesAreFoundWhenTheServerIgnoresTheHeaderFilter() async throws {
        await account.start()
        server.ignoresHeaderFilter = true
        let (composer, _) = try await savedDraft()
        server.advanceClock(by: 2)
        composer.body = AttributedString("Make it one")
        account.transport.beforeNext("Email/set") { [server] in server.loseNextResponse() }
        await composer.saveNow()
        server.advanceClock(by: 2)

        composer.body = AttributedString("Make it half past")
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        #expect(try await account.copies(of: row.messageID) == [try #require(row.serverEmailID): ["drafts": true]])
        #expect(composer.notices.isEmpty)
    }

    // MARK: Other devices (D10)

    @Test func aDraftEditedOnAnotherDeviceKeepsBothVersions() async throws {
        await account.start()
        let (composer, first) = try await savedDraft()
        let messageID = composer.draft.messageID
        server.advanceClock(by: 30)
        let theirs = try #require(server.editDraftOnAnotherDevice(emailID: first))
        server.advanceClock(by: 30)

        composer.body = AttributedString("Mine")
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        let mine = try #require(row.serverEmailID)
        #expect(row.messageID != messageID && composer.draft.messageID == row.messageID)
        #expect(composer.notices == [.otherVersionKept])
        #expect(try await account.copies(of: messageID) == [theirs: ["drafts": true]])
        #expect(try await account.copies(of: row.messageID) == [mine: ["drafts": true]])
        #expect(try await account.serverEmail(mine)?.bodyValues?["text"]?.value.hasPrefix("Mine") == true)
        #expect(try await account.serverEmail(theirs)?.bodyValues?["text"]?.value.contains("Changed on another device") == true)
    }

    @Test func aDraftTrashedElsewhereWithoutChangesHereIsDeleted() async throws {
        await account.start()
        let (composer, copy) = try await savedDraft()
        await composer.close()
        server.advanceClock(by: 5)
        server.moveToTrash(emailID: copy)

        await model.refresh()
        await account.settle()

        #expect(try await account.row(composer.id) == nil)
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["trash": true])
    }

    @Test func aDraftTrashedElsewhereWithChangesHereIsSavedAgain() async throws {
        await account.start()
        let (composer, copy) = try await savedDraft()
        server.advanceClock(by: 5)
        server.moveToTrash(emailID: copy)
        await model.refresh()

        composer.body = AttributedString("Still want to go")
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        let current = try #require(row.serverEmailID)
        #expect(current != copy)
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["trash": true])
        #expect(try await account.serverEmail(current)?.mailboxIds == ["drafts": true])
        #expect(composer.notices == [.deletedElsewhereRestored])
    }

    /// Another device sent the draft and removed its copy, as clients do; this device then saves.
    private func sentElsewhere() async throws -> (Composer, String) {
        await account.start()
        let (composer, copy) = try await savedDraft()
        let messageID = composer.draft.messageID
        server.advanceClock(by: 30)
        server.sendFromAnotherDevice(messageID: messageID, subject: "Lunch")
        server.destroyEmail(id: copy)
        server.advanceClock(by: 30)
        composer.body = AttributedString("Wait, one more thing")
        await composer.saveNow()
        #expect(composer.notices == [.sentElsewhere])
        return (composer, messageID)
    }

    @Test func aDraftSentElsewhereCanBeKeptAsANewMessage() async throws {
        let (composer, messageID) = try await sentElsewhere()

        await composer.keepAsNewMessage()
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        #expect(row.messageID != messageID)
        #expect(try await account.copies(of: row.messageID) == [try #require(row.serverEmailID): ["drafts": true]])
        #expect(try await account.copies(of: messageID).values.map { $0 } == [["sent": true]])
        #expect(composer.notices.isEmpty)
    }

    @Test func aDraftSentElsewhereGoesWhenClosed() async throws {
        let (composer, messageID) = try await sentElsewhere()

        await composer.close()
        await account.settle()

        #expect(try await account.row(composer.id) == nil)
        #expect(try await account.copies(of: messageID).values.map { $0 } == [["sent": true]])
    }

    @Test func aDraftSentElsewhereIsSentOnlyOnceKeptAsANewMessage() async throws {
        let (composer, messageID) = try await sentElsewhere()
        composer.body = AttributedString("Wait, one more thing: bring the tickets")

        #expect(composer.problems.first == .sentElsewhere)
        await #expect(throws: SendProblem.sentElsewhere) { try await composer.send() }
        await #expect(throws: SendProblem.sentElsewhere) { try await outbox.send(composer.draft) }
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .editing)
        #expect(await model.composer(id: composer.id) === composer)

        await composer.keepAsNewMessage()
        #expect(composer.problems.isEmpty)
        try await composer.send()
        await account.settle()
        await account.advance(17)

        let sent = try #require(server.sentMessages.first)
        #expect(server.sentMessages.count == 1 && sent.messageId != messageID)
        let text = try await account.serverEmail(sent.emailId)?.bodyValues?["text"]?.value
        #expect(text?.hasPrefix("Wait, one more thing: bring the tickets") == true)
    }

    // MARK: Deleting (D11)

    @Test func anEditWhileTheDraftIsDeletedDoesNotBringItBack() async throws {
        await account.start()
        let (composer, copy) = try await savedDraft()
        let creates = account.transport.arguments(of: "Email/set").filter(\.creates).count
        // The move to Trash waits.
        account.transport.hold("Email/set")

        let discard = Task { await composer.discard() }
        #expect(await eventually { account.transport.heldRequests == 1 })
        composer.body = AttributedString("Typed while deleting")
        account.transport.release("Email/set")
        #expect(await discard.value == .discarded)
        await account.advance(6)

        #expect(try await account.row(composer.id) == nil)
        #expect(account.transport.arguments(of: "Email/set").filter(\.creates).count == creates)
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["trash": true])
    }

    // MARK: Uploads (C28)

    @Test func aServerSaveWaitsForARunningUpload() async throws {
        await account.start()
        account.transport.hold(OutboxTestTransport.upload)
        let composer = try await account.composeToMaya()
        try await composer.addAttachment(Data("Packing list".utf8), name: "List.txt", typeIdentifier: "public.plain-text")

        let save = Task { await composer.saveNow() }
        #expect(await eventually { outbox.draftsWaitingForUploads.contains(composer.id.uuidString) })
        #expect(account.transport.calls(to: "Email/set") == 0)
        account.transport.release(OutboxTestTransport.upload)
        await save.value

        let copy = try #require(try await account.row(composer.id)?.serverEmailID)
        #expect(try await account.serverEmail(copy)?.attachments?.map(\.name) == ["List.txt"])
        #expect(composer.notices.isEmpty)
    }

    @Test func aServerSaveWaitsAMinuteAtMostForUploads() async throws {
        await account.start()
        account.transport.hold(OutboxTestTransport.upload)
        let composer = try await account.composeToMaya()
        try await composer.addAttachment(Data("Packing list".utf8), name: "List.txt", typeIdentifier: "public.plain-text")
        let save = Task { await composer.saveNow() }
        #expect(await eventually { outbox.draftsWaitingForUploads.contains(composer.id.uuidString) })

        server.advanceClock(by: 60)
        await save.value

        let copy = try #require(try await account.row(composer.id)?.serverEmailID)
        #expect(try await account.serverEmail(copy)?.attachments == [])
        #expect(composer.notices == [.attachmentsNotOnServerYet])

        account.transport.release(OutboxTestTransport.upload)
        await outbox.waitUntilIdle()
        composer.subject = "Lunch, with list"
        await composer.saveNow()
        let next = try #require(try await account.row(composer.id)?.serverEmailID)
        #expect(try await account.serverEmail(next)?.attachments?.map(\.name) == ["List.txt"])
    }

    // MARK: Drafts from other clients (D32)

    @Test func aDraftFromAnotherClientOpensReadOnlyAndEditingItTrashesTheOriginal() async throws {
        await account.start()
        let html = "<div>The plan</div><table><tr><td>Day 1</td><td>Alfama</td></tr></table>"
        let body = EmailCreate.body(text: "The plan\nDay 1\tAlfama", html: html, inline: [], attachments: [])
        let foreign = try #require(try await account.client.saveDraft(EmailCreate(
            mailboxIds: ["drafts": true], keywords: ["$draft": true, "$seen": true],
            messageId: ["plan-1@fastmail.com"], from: [EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")],
            to: [maya], subject: "Plan", sentAt: account.clock.now, bodyStructure: body.structure,
            bodyValues: body.values), replacing: nil).createdID)
        await model.refresh()

        let preview = try await model.compose(.draft(emailID: foreign))
        #expect(preview.mode == .preview([.tables]))
        #expect(preview.previewHTML?.contains("<table>") == true)
        await preview.close()
        await account.settle()
        #expect(try await account.row(preview.id) == nil)
        #expect(try await account.serverEmail(foreign)?.mailboxIds == ["drafts": true])

        let composer = try await model.compose(.draft(emailID: foreign))
        composer.editAnyway()
        #expect(composer.mode == .editing && composer.previewHTML == nil)
        composer.body = AttributedString("The plan, simplified")
        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        let copy = try #require(row.serverEmailID)
        #expect(copy != foreign)
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["drafts": true])
        #expect(try await account.serverEmail(foreign)?.mailboxIds == ["trash": true])
        #expect(row.record.trashOnFirstSave == nil)
    }

    @Test func deletingADraftOpenedFromTheServerMovesItToTrash() async throws {
        await account.start()
        let composer = try await model.compose(.draft(emailID: "e15"))

        #expect(await composer.discard() == .discarded)
        await account.settle()

        #expect(try await account.serverEmail("e15")?.mailboxIds == ["trash": true])
    }

    @Test func deletingADraftOpenedFromTheServerRightAfterEditingItMovesItToTrash() async throws {
        await account.start()
        let composer = try await model.compose(.draft(emailID: "e15"))
        // Deleted within the second before the edit is saved on the device.
        composer.body = AttributedString("Never mind")

        #expect(await composer.discard() == .discarded)
        await account.advance(6)

        #expect(try await account.serverEmail("e15")?.mailboxIds == ["trash": true])
        #expect(try await account.row(composer.id) == nil)
        #expect(account.transport.arguments(of: "Email/set").filter(\.creates).isEmpty)
    }
}

private extension JSONValue {
    /// Whether this `Email/set` call creates an email.
    var creates: Bool {
        if case .object(let arguments) = self, case .object(let create)? = arguments["create"] { !create.isEmpty } else { false }
    }
}
