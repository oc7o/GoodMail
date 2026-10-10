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
        for _ in 0..<50_000 {
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

    @Test func aLostAnswerWhoseMessageWentOutMeanwhileIsFinalized() async throws {
        await account.start()
        account.transport.beforeNext("EmailSubmission/set") { [server] in server.loseNextResponse() }
        let id = try await send()
        #expect(try await account.row(id)?.state == .submitting)

        await account.advance(20)

        #expect(try await account.row(id) == nil)
        #expect(server.sentMessages.count == 1)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 1)
        #expect(outbox.items.isEmpty)
    }

    @Test func aLostAnswerToARefusedSubmissionIsSentOnceMore() async throws {
        await account.start()
        account.transport.beforeNext("EmailSubmission/set") { [server] in
            server.failNextSubmission(methodError: "invalidArguments")
            server.loseNextResponse()
        }
        let id = try await send()
        let messageID = try #require(try await account.row(id)).messageID
        #expect(try await account.copies(of: messageID).count == 1)

        await account.settle()

        // The stray email of the lost attempt is gone, and the message went again, once.
        #expect(try await account.row(id)?.state == .held)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 2)
        #expect(try await account.copies(of: messageID).values.map { $0 } == [["sent": true]])
        await account.advance(17)
        #expect(server.sentMessages.count == 1)
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

    @Test func aSubmissionThatNeverWentOutIsSentAgainAtOnceThenWithBackoff() async throws {
        await account.start()
        for _ in 0..<10 { account.transport.failNext("EmailSubmission/set", with: .timedOut) }
        let start = account.clock.now

        let id = try await send()
        #expect(try await account.row(id)?.state == .submitting)
        for _ in 0..<6 { await account.advance(5) }

        // Verified at 5 s and sent again at once; verified at 10 s and left to wait like for a busy server.
        #expect(account.transport.calls(to: "EmailSubmission/set") == 2)
        #expect(outbox.items.map(\.state) == [.waiting(.retry(at: start + 70))])
        await account.advance(40)
        #expect(account.transport.calls(to: "EmailSubmission/set") == 3)
        #expect(server.pendingSubmissionIDs.isEmpty && server.sentMessages.isEmpty)
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

    @Test func aSubmissionThatLeftItsEmailInDraftsCountsAsSentOnceReleased() async throws {
        await account.start()
        account.transport.afterNext("EmailSubmission/set", Self.failingImplicitUpdate)
        let id = try await send()
        await account.settle()
        let submission = try #require(try await account.record(id)?.submission)
        #expect(submission.movedToSent == false)
        // Where the email is when the submission's update of it failed: a draft in Drafts.
        let patch = PatchObject.move(from: "sent", to: "drafts").merging(.setKeyword(.draft, true))
        #expect(try await account.client.updateEmails([submission.emailID: patch]).isEmpty)

        await account.advance(17)

        // Not taken for a cancel on another device, which would offer to send it again.
        #expect(try await account.row(id) == nil)
        #expect(outbox.notices.isEmpty)
        #expect(server.sentMessages.count == 1)
        let email = try #require(try await account.serverEmail(submission.emailID))
        #expect(email.mailboxIds == ["sent": true] && !email.has(.draft))
    }

    /// The answer to a submission whose implicit `Email/set` couldn't update the email.
    private static let failingImplicitUpdate: @Sendable (JSONValue) -> JSONValue = { answer in
        guard case .object(var envelope) = answer, case .array(let responses)? = envelope["methodResponses"] else {
            return answer
        }
        envelope["methodResponses"] = .array(responses.map { response in
            guard case .array(var call) = response, call.count == 3, call[0] == "Email/set",
                  case .object(var arguments) = call[1], case .object(let updated)? = arguments["updated"],
                  !updated.isEmpty
            else { return response }
            arguments["updated"] = .object([:])
            arguments["notUpdated"] = .object(updated.mapValues { _ in ["type": "invalidPatch"] })
            call[1] = .object(arguments)
            return .array(call)
        })
        return .object(envelope)
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

    /// Sends a message to Maya whose submission request waits until released, and cancels or deletes it while
    /// the request is out.
    private func sendThenStopWhileSending(discarding: Bool = false) async throws -> UUID {
        let composer = try await account.composeToMaya()
        account.transport.hold("EmailSubmission/set")
        try await composer.send()
        #expect(await eventually { account.transport.heldRequests == 1 })
        #expect(try await account.row(composer.id)?.state == .submitting)
        if discarding {
            #expect(await outbox.discard(composer.id) == .requested)
        } else {
            #expect(await outbox.cancel(composer.id) == .requested)
        }
        #expect(outbox.items.map(\.state) == [.cancelling])
        return composer.id
    }

    @Test func cancelWhileSendingHoldsWhenFastmailRefusesTheHold() async throws {
        await account.start()
        server.rejectsHoldFor = true
        let id = try await sendThenStopWhileSending()

        account.transport.release("EmailSubmission/set")
        await account.settle()

        let row = try #require(try await account.row(id))
        #expect(row.state == .editing && !row.record.cancelRequested)
        #expect(outbox.notices == [.canceled("Lunch")])
        #expect(outbox.items.isEmpty && outbox.undoable == nil)
        #expect(model.account?.serverHoldUnsupported == true)
        await account.advance(30)
        #expect(server.sentMessages.isEmpty)
        // The email of the refused submission is gone; the draft is saved to Drafts again.
        let draftCopy = try #require(try await account.row(id)?.serverEmailID)
        #expect(try await account.copies(of: row.messageID) == [draftCopy: ["drafts": true]])
    }

    @Test func cancelWhileSendingOfAMessageFastmailRefusesMakesItADraftAgain() async throws {
        await account.start()
        let id = try await sendThenStopWhileSending()
        server.failNextSubmission(methodError: "forbidden")

        account.transport.release("EmailSubmission/set")
        await account.settle()

        let row = try #require(try await account.row(id))
        #expect(row.state == .editing && row.record.failure == nil && !row.record.cancelRequested)
        #expect(outbox.notices == [.canceled("Lunch")] && outbox.items.isEmpty)
        let draftCopy = try #require(row.serverEmailID)
        #expect(try await account.copies(of: row.messageID) == [draftCopy: ["drafts": true]])
        #expect(await model.composer(id: id)?.subject == "Lunch")
    }

    @Test func deleteWhileSendingOfAMessageFastmailRefusesDeletesIt() async throws {
        await account.start()
        let id = try await sendThenStopWhileSending(discarding: true)
        server.rejectNextSubmission(SetError(type: SetError.forbiddenToSend, description: "Daily limit reached"))

        account.transport.release("EmailSubmission/set")
        await account.settle()

        #expect(try await account.row(id) == nil)
        #expect(outbox.notices == [.canceled("Lunch")] && outbox.items.isEmpty)
        await account.advance(30)
        #expect(server.sentMessages.isEmpty)
    }

    @Test func aCancelArrivingWithTheSubmissionsAnswerIsNeverLost() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        account.transport.hold("EmailSubmission/set")
        try await composer.send()
        #expect(await eventually { account.transport.heldRequests == 1 })

        // The cancel goes as far as its first look at the store; then the answer is stored off the main actor
        // while the main actor is kept busy, so that the cancel carries on only after that.
        let started = CancelStarted()
        let cancel = Task {
            started.value = true
            return await outbox.cancel(composer.id)
        }
        while !started.value { await Task.yield() }
        account.transport.release("EmailSubmission/set")
        let busyUntil = ContinuousClock.now + .milliseconds(200)
        while ContinuousClock.now < busyUntil {}
        let outcome = await cancel.value
        await account.settle()
        await account.advance(20)

        #expect(outcome == .requested || outcome == .backToDrafts)
        #expect(try await account.row(composer.id)?.state == .editing)
        #expect(server.sentMessages.isEmpty)
    }

    @Test func retryIsANewSendWithoutTheFlagsOfTheLastOne() async throws {
        await account.start()
        server.rejectNextSubmission(SetError(type: SetError.forbiddenToSend, description: "Daily limit reached"))
        let id = try await send()
        await account.settle()
        #expect(try await account.row(id)?.state == .failed)
        // As left by a cancel asked for during an earlier try.
        try await account.store.updateOutbox(id: id.uuidString) { _, record in
            record.cancelRequested = true
            record.discardRequested = true
        }

        outbox.retry(id)
        #expect(try await eventually { try await account.row(id)?.state == .held })
        await account.settle()

        #expect(try await account.row(id)?.state == .held)
        #expect(outbox.notices.isEmpty)
        await account.advance(17)
        #expect(server.sentMessages.count == 1)
    }

    // MARK: A Send changed while its pass waits

    @Test func aMessageSentAgainWhileItsUploadRunsGoesOutAsSentAgain() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let id = composer.id
        // Attached offline, so that the upload starts only once the send needs it.
        await account.setOnline(false)
        try await composer.addAttachment(Data("Agenda".utf8), name: "Agenda.txt", typeIdentifier: "public.plain-text")
        await account.setOnline(true)
        account.transport.hold(OutboxTestTransport.upload)
        try await composer.send()
        #expect(await eventually { account.transport.heldRequests == 1 })

        #expect(await outbox.cancel(id) == .backToDrafts)
        let reopened = try #require(await model.composer(id: id))
        reopened.to = [EmailAddress(name: "Lena", email: "lena@example.com")]
        try await reopened.send()
        account.transport.release(OutboxTestTransport.upload)
        await account.settle()
        await account.advance(17)

        let sent = try #require(server.sentMessages.first)
        let messageID = try #require(sent.messageId)
        #expect(server.sentMessages.count == 1)
        #expect(sent.rcptTo == ["lena@example.com"])
        #expect(try await account.serverEmail(sent.emailId)?.attachments?.map(\.name) == ["Agenda.txt"])
        #expect(try await account.copies(of: messageID).values.map { $0 } == [["sent": true]])
        #expect(try await account.row(id) == nil)
    }

    @Test func aMessageSentAgainWhileItsPreCheckRunsKeepsItsNewContent() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        await model.refresh()
        await account.settle()
        let id = composer.id
        let messageID = composer.draft.messageID
        let draftCopy = try #require(try await account.row(id)?.serverEmailID)
        let theirs = try #require(server.editDraftOnAnotherDevice(emailID: draftCopy))
        account.transport.hold("Email/query")
        try await composer.send()
        #expect(await eventually { account.transport.heldRequests == 1 })

        #expect(await outbox.cancel(id) == .backToDrafts)
        let reopened = try #require(await model.composer(id: id))
        reopened.body = AttributedString("Make it one")
        try await reopened.send()
        account.transport.release("Email/query")
        await account.settle()
        await account.advance(17)

        // Another device's version is kept, and the one sent is the message as sent again.
        let sent = try #require(server.sentMessages.first)
        #expect(server.sentMessages.count == 1)
        #expect(sent.messageId != messageID)
        #expect(try await account.serverEmail(sent.emailId)?.bodyValues?["text"]?.value.hasPrefix("Make it one") == true)
        #expect(try await account.serverEmail(theirs)?.mailboxIds == ["drafts": true])
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

/// Whether a task on the main actor has begun.
@MainActor
private final class CancelStarted {
    var value = false
}
