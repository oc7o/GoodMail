import DemoAccount
import Foundation
import JMAPKit
import MailCompose
import MailStore
import Testing
@testable import GoodMailCore

/// What goes wrong while sending, and that no message ever goes out twice or gets lost (C2, C3, C4, C23,
/// C24, C29, D14, D21), against the demo account's failure modes.
@MainActor
struct OutboxFailureTests {
    let account: OutboxTestAccount
    var model: MailModel { account.model }
    var outbox: Outbox { account.outbox }
    var server: DemoTransport { account.server }
    let maya = EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")
    let fjord = "fjord.k3x9@fastmail.com"

    init() throws {
        account = try OutboxTestAccount()
    }

    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0..<2000 {
            if try await condition() { return true }
            await Task.yield()
        }
        return try await condition()
    }

    /// Sends a message to Maya and waits until its first try is over.
    private func send(subject: String = "Lunch") async throws -> UUID {
        let composer = try await account.composeToMaya(subject: subject)
        try await composer.send()
        await account.flushed()
        return composer.id
    }

    // MARK: Unknown outcomes (D14)

    @Test func aLostAnswerIsVerifiedAndNeverSentAgain() async throws {
        await account.start()
        account.transport.beforeNext("EmailSubmission/set") { [server] in server.loseNextResponse() }

        let id = try await send()

        #expect(try await account.row(id)?.state == .submitting)
        #expect(outbox.items.map(\.state) == [.sending])
        #expect(server.pendingSubmissionIDs.count == 1)

        await account.settle()

        #expect(try await account.row(id)?.state == .held)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 1)
        #expect(account.transport.calls(to: "EmailSubmission/query") == 1)
        #expect(outbox.undoable?.id == id)
        await account.advance(17)
        #expect(server.sentMessages.count == 1)
        #expect(try await account.row(id) == nil)
    }

    @Test func aBusyAnswerAfterTheWorkIsVerifiedAndNeverSentAgain() async throws {
        let account = try OutboxTestAccount(maxRetries: 3)
        await account.start()
        account.transport.beforeNext("EmailSubmission/set") { [server = account.server] in
            server.answerNext(withStatus: 503)
        }
        let composer = try await account.composeToMaya()
        try await composer.send()
        await account.flushed()
        #expect(try await account.row(composer.id)?.state == .submitting)

        await account.settle()

        #expect(try await account.row(composer.id)?.state == .held)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 1)
        await account.advance(17)
        #expect(account.server.sentMessages.count == 1)
    }

    @Test func aRequestThatFailedBeforeTheServerIsNeverShownAsSending() async throws {
        await account.start()
        account.transport.failNext("EmailSubmission/set", with: .notConnectedToInternet)

        let id = try await send()

        #expect(try await account.row(id)?.state == .queued)
        #expect(outbox.items.map(\.state) == [.waiting(.offline)])
        #expect(server.pendingSubmissionIDs.isEmpty)
        await account.advance(30)
        #expect(try await account.row(id)?.state == .held)
    }

    @Test func serverUnavailableAfterTheEmailWasMadeRetriesLaterAndCleansUp() async throws {
        await account.start()
        server.failNextSubmission(methodError: MethodError.serverUnavailable)
        let start = account.clock.now

        let id = try await send()
        await account.settle()

        let row = try #require(try await account.row(id))
        #expect(row.state == .queued)
        #expect(row.record.wait == .busy)
        #expect(outbox.items.map(\.state) == [.waiting(.retry(at: start + 30))])
        #expect(try await account.copies(of: row.messageID).isEmpty)

        await account.advance(30)
        #expect(try await account.row(id)?.state == .held)
        await account.advance(17)
        #expect(server.sentMessages.count == 1)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 2)
    }

    // MARK: Holds

    @Test func aRefusedHoldSwitchesToTheUndoWindowOnThisDevice() async throws {
        await account.start()
        server.rejectsHoldFor = true
        let start = account.clock.now

        let first = try await send()
        await account.settle()

        #expect(try await account.row(first)?.state == .queued)
        #expect(outbox.items.map(\.state) == [.waiting(.localUndo(until: start + 10))])
        #expect(outbox.undoable == Outbox.UndoableSend(id: first, subject: "Lunch", undoUntil: start + 10))
        #expect(model.account?.serverHoldUnsupported == true)
        let stored = try #require(try await account.store.keyedData("account"))
        #expect(try JSONDecoder().decode(AccountSnapshot.self, from: stored).serverHoldUnsupported)
        #expect(try await account.copies(of: try #require(try await account.row(first)).messageID).isEmpty)

        await account.advance(10)
        #expect(try await account.row(first) == nil)
        #expect(server.sentMessages.count == 1)
        #expect(server.pendingSubmissionIDs.isEmpty)

        // From now on the Undo window passes here before Fastmail is asked at all.
        let second = try await send(subject: "Dinner")
        #expect(outbox.undoable?.id == second)
        #expect(await outbox.cancel(second) == .backToDrafts)
        await account.advance(20)
        #expect(server.sentMessages.count == 1)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 2)
    }

    @Test func tooLargeFailsAndLeavesTheDraftOnTheServer() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        let id = composer.id
        let draftCopy = try #require(try await account.row(id)?.serverEmailID)
        server.rejectNextSubmission(SetError(type: SetError.tooLarge, maxSize: 1000))

        try await composer.send()
        await account.settle()

        let row = try #require(try await account.row(id))
        #expect(row.state == .failed)
        #expect(outbox.items.map(\.state) == [.failed(.tooLarge(limit: 1000))])
        #expect(row.serverEmailID == draftCopy)
        #expect(try await account.copies(of: row.messageID) == [draftCopy: ["drafts": true]])

        let edit = try #require(await model.composer(id: id))
        #expect(try await account.row(id)?.state == .editing)
        await edit.close()
        await account.settle()
        #expect(try await account.row(id)?.serverEmailID == draftCopy)
        #expect(try await account.copies(of: row.messageID) == [draftCopy: ["drafts": true]])
        #expect(outbox.items.isEmpty)
    }

    @Test func failedMessagesCanBeSentAgain() async throws {
        await account.start()
        server.rejectNextSubmission(SetError(type: SetError.forbiddenToSend, description: "Daily limit reached"))

        let id = try await send()
        await account.settle()
        #expect(outbox.items.map(\.state) == [.failed(.refused(type: SetError.forbiddenToSend, description: "Daily limit reached"))])
        #expect(OutboxFailure.refused(type: "forbiddenToSend", description: "Daily limit reached").localizedDescription == "Daily limit reached")

        outbox.retry(id)
        #expect(try await eventually { try await account.row(id)?.state == .held })
    }

    // MARK: Cancel and discard (C3)

    @Test func discardWhileHeldIsNeverDelivered() async throws {
        await account.start()
        let id = try await send()
        await account.settle()
        let sentCopy = try #require(try await account.row(id)?.serverEmailID)

        #expect(await outbox.discard(id) == .discarded)

        #expect(try await account.row(id) == nil)
        await account.advance(20)
        #expect(server.sentMessages.isEmpty)
        #expect(try await account.serverEmail(sentCopy)?.mailboxIds == ["trash": true])
    }

    @Test func discardWhileTheOutcomeIsUnknownWaitsForVerification() async throws {
        await account.start()
        account.transport.beforeNext("EmailSubmission/set") { [server] in server.loseNextResponse() }
        let id = try await send()
        #expect(try await account.row(id)?.state == .submitting)

        #expect(await outbox.discard(id) == .requested)
        #expect(outbox.items.map(\.state) == [.cancelling])
        #expect(try await account.row(id) != nil)

        await account.settle()

        #expect(try await account.row(id) == nil)
        #expect(outbox.notices == [.canceled("Lunch")])
        await account.advance(20)
        #expect(server.sentMessages.isEmpty)
    }

    @Test func cancelWhileSendingOfAMessageThatNeverWentOutBringsItBack() async throws {
        await account.start()
        account.transport.failNext("EmailSubmission/set", with: .timedOut)
        let id = try await send()
        #expect(try await account.row(id)?.state == .submitting)

        #expect(await outbox.cancel(id) == .requested)
        await account.settle()

        #expect(try await account.row(id)?.state == .editing)
        #expect(outbox.notices == [.canceled("Lunch")])
        #expect(server.pendingSubmissionIDs.isEmpty && server.sentMessages.isEmpty)
    }

    @Test func undoWhoseAnswerIsLostCountsAsOursOnceTheEmailIsBackInDrafts() async throws {
        await account.start()
        let id = try await send()
        await account.settle()
        let start = try #require(try await account.record(id)?.submission?.submittedAt)
        account.transport.beforeNext("EmailSubmission/set") { [server] in server.loseNextResponse() }

        #expect(await outbox.cancel(id) == .unreachable(sendsAround: start + 15))

        #expect(outbox.items.map(\.state) == [.cancelling])
        #expect(server.pendingSubmissionIDs.isEmpty)
        await account.advance(17)
        #expect(try await account.row(id)?.state == .editing)
        #expect(outbox.notices == [.canceled("Lunch")])
        #expect(server.sentMessages.isEmpty)
    }

    @Test func undoWhileFastmailIsUnreachableLetsTheMessageGo() async throws {
        await account.start()
        let id = try await send()
        await account.settle()
        let start = try #require(try await account.record(id)?.submission?.submittedAt)
        server.isOffline = true

        #expect(await outbox.cancel(id) == .unreachable(sendsAround: start + 15))
        #expect(try await account.row(id)?.state == .held)

        server.isOffline = false
        await account.advance(17)
        #expect(server.sentMessages.count == 1)
        #expect(try await account.row(id) == nil)
    }

    @Test func undoAfterTheDeadlineIsTooLate() async throws {
        await account.start()
        let id = try await send()
        await account.settle()

        server.advanceClock(by: 14)

        #expect(await outbox.cancel(id) == .alreadySent)
        await account.settle()
        await account.advance(3)
        #expect(server.sentMessages.count == 1)
    }

    @Test func aSubmissionCancelledOnAnotherDeviceComesBackAsADraft() async throws {
        await account.start()
        let id = try await send()
        await account.settle()
        let submission = try #require(try await account.record(id)?.submission)

        #expect(try await account.client.cancelSubmission(
            submission.id, mailboxes: MailboxRoles(drafts: "drafts", sent: "sent")) == .canceled)
        await account.advance(17)

        let row = try #require(try await account.row(id))
        #expect(row.state == .editing && row.serverEmailID == submission.emailID)
        #expect(outbox.notices == [.canceledElsewhere("Lunch")])
        #expect(await model.composer(id: id)?.subject == "Lunch")
    }

    // MARK: Other devices (C29)

    @Test func aMessageAnotherDeviceSentIsNotSentAgain() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        let draftCopy = try #require(try await account.row(composer.id)?.serverEmailID)
        server.sendFromAnotherDevice(messageID: composer.draft.messageID, subject: "Lunch")

        try await composer.send()
        await account.settle()

        #expect(try await account.row(composer.id) == nil)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 0)
        #expect(outbox.notices == [.sentElsewhere("Lunch")])
        #expect(try await account.serverEmail(draftCopy) == nil)
        #expect(server.sentMessages.isEmpty)
    }

    @Test func anotherDevicesDraftOfTheMessageIsKeptAndThisOneSentUnderANewID() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        let messageID = composer.draft.messageID
        let draftCopy = try #require(try await account.row(composer.id)?.serverEmailID)
        let theirs = try #require(server.editDraftOnAnotherDevice(emailID: draftCopy))
        // This device never saw the other version, so it still thinks its copy is current.
        try await composer.send()
        await account.settle()

        let row = try #require(try await account.row(composer.id))
        #expect(row.state == .held)
        #expect(row.messageID != messageID && row.messageID.hasSuffix("@fastmail.com"))
        #expect(try await account.serverEmail(theirs)?.mailboxIds == ["drafts": true])
        #expect(row.record.notice == .otherVersionKept)
    }

    // MARK: Uploads

    @Test func uploadsTheServerForgotAreUploadedAgain() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        try await composer.addAttachment(Data("Packing list".utf8), name: "List.txt", typeIdentifier: "public.plain-text")
        await outbox.waitUntilIdle()
        #expect(server.uploadCount == 1)
        server.expireUploads()

        try await composer.send()
        await account.settle()

        #expect(try await account.row(composer.id)?.state == .held)
        #expect(server.uploadCount == 2)
        await account.advance(17)
        let sent = try #require(server.sentMessages.first)
        #expect(try await account.serverEmail(sent.emailId)?.attachments?.map(\.name) == ["List.txt"])
    }

    @Test func aForwardedFileThatIsGoneFailsTheMessage() async throws {
        await account.start()
        let composer = try await model.compose(.forward(emailID: "e3", asAttachment: false))
        composer.to = [maya]
        server.destroyEmail(id: "e3")

        try await composer.send()
        await account.settle()

        #expect(outbox.items.map(\.state) == [.failed(.attachmentUnavailable("Flight confirmation.pdf"))])
    }

    // MARK: The token and identities (D18, D21)

    @Test func aTokenWithoutSubmissionSavesDraftsButSendsNothing() async throws {
        let account = try OutboxTestAccount(supportsSubmission: false)
        await account.start()
        let model = account.model
        #expect(model.sendAvailability == .tokenLacksSubmission)
        let composer = try await account.composeToMaya()
        #expect(composer.problems == [.cannotSend(.tokenLacksSubmission)])
        await #expect(throws: SendProblem.cannotSend(.tokenLacksSubmission)) { try await composer.send() }

        await composer.saveNow()
        #expect(try await account.row(composer.id)?.serverEmailID != nil)

        // A message queued while the token could still send.
        let queued = MessageDraft(from: EmailAddress(email: "alex@fastmail.com"), to: [maya], subject: "Queued")
        try await account.store.saveDraftContent(
            id: queued.id.uuidString, content: try MailSend.encode(queued), messageID: queued.messageID, state: .queued)
        await account.settle()
        #expect(model.outbox.items.map(\.state) == [.failed(.tokenLacksSubmission)])
        #expect(account.transport.calls(to: "Identity/get") == 0)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 0)
        #expect(account.transport.eventSourceURLs.isEmpty)
    }

    @Test func aMaskWithoutSendingIdentityStaysADraftWhileGoodMailMayNotCreateOne() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        composer.from = EmailAddress(email: fjord)

        #expect(composer.problems == [.needsSendingIdentity(fjord)])
        await #expect(throws: SendProblem.needsSendingIdentity(fjord)) {
            try await composer.send(consentingToSendingIdentityFor: fjord)
        }
        #expect(SendProblem.needsSendingIdentity(fjord).localizedDescription.contains("Settings → My email addresses"))
        #expect(account.transport.calls(to: "Identity/set") == 0)
        #expect(try await account.row(composer.id)?.state != .queued)
    }

    @Test func consentCreatesTheIdentityForExactlyThatAddress() async throws {
        await account.start()
        outbox.maskedSending.createsIdentities = true
        let composer = try await account.composeToMaya()
        composer.from = EmailAddress(email: fjord)
        #expect(composer.problems.isEmpty)

        await #expect(throws: SendProblem.needsSendingIdentity(fjord)) { try await composer.send() }
        await #expect(throws: SendProblem.needsSendingIdentity(fjord)) {
            try await composer.send(consentingToSendingIdentityFor: "paperplane.x2m4@fastmail.com")
        }
        try await composer.send(consentingToSendingIdentityFor: fjord)
        await account.settle()

        #expect(try await account.row(composer.id)?.state == .held)
        #expect(account.transport.calls(to: "Identity/set") == 1)
        let identity = try #require(model.identities.first { $0.email == fjord })
        await account.advance(17)
        let sent = try #require(server.sentMessages.first)
        #expect(sent.from == fjord && sent.mailFrom == fjord && sent.identityId == identity.id)

        // Consent for one mask is no consent for another (C24).
        let other = try await account.composeToMaya(subject: "Again")
        other.from = EmailAddress(email: "paperplane.x2m4@fastmail.com")
        await #expect(throws: SendProblem.needsSendingIdentity("paperplane.x2m4@fastmail.com")) {
            try await other.send(consentingToSendingIdentityFor: fjord)
        }
        // The identity made for the first one needs no consent any more.
        other.from = EmailAddress(email: fjord)
        try await other.send()
        await account.settle()
        #expect(account.transport.calls(to: "Identity/set") == 1)
    }

    @Test func anIdentityWhoseCreationAnswerWasLostIsReadNotMadeAgain() async throws {
        await account.start()
        outbox.maskedSending.createsIdentities = true
        account.transport.beforeNext("Identity/set") { [server] in server.loseNextResponse() }
        let composer = try await account.composeToMaya()
        composer.from = EmailAddress(email: fjord)
        try await composer.send(consentingToSendingIdentityFor: fjord)
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .queued)

        await account.advance(30)

        #expect(try await account.row(composer.id)?.state == .held)
        #expect(account.transport.calls(to: "Identity/set") == 1)
        #expect(model.identities.filter { $0.email == fjord }.count == 1)
    }
}
