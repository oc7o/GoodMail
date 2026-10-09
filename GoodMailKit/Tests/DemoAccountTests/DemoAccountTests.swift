import Foundation
import JMAPKit
import Testing
@testable import DemoAccount

/// `JMAPClient` against the demo server on a manual clock, as the outbox tests in GoodMailCore use it.
struct DemoAccountTests {
    /// 2026-10-09T14:00:00Z
    static let start = Date(timeIntervalSince1970: 1_791_554_400)
    let clock = DemoClock(manualStart: DemoAccountTests.start)
    let server: DemoTransport
    let client: JMAPClient
    let mailboxes = MailboxRoles(drafts: "drafts", sent: "sent")

    init() {
        server = DemoTransport(clock: clock)
        client = JMAPClient(token: "demo", transport: server, maxRetries: 0)
    }

    func draft(
        subject: String = "Lunch", from: String = "alex@fastmail.com", name: String? = "Alex Berg",
        to: [String] = ["maya@lindqvist.example"], messageID: String = "lunch-1@fastmail.com",
        inReplyTo: [String]? = nil, attachments: [EmailBodyPartCreate] = []
    ) -> EmailCreate {
        let body = EmailCreate.body(
            text: "See you at noon", html: "<div>See you at noon</div>", inline: [], attachments: attachments)
        return EmailCreate(
            mailboxIds: ["drafts": true], keywords: ["$draft": true, "$seen": true], messageId: [messageID],
            inReplyTo: inReplyTo, references: inReplyTo, from: [EmailAddress(name: name, email: from)],
            to: to.map { EmailAddress(email: $0) }, subject: subject, sentAt: clock.now,
            bodyStructure: body.structure, bodyValues: body.values)
    }

    func envelope(
        from: String = "alex@fastmail.com", to: [String] = ["maya@lindqvist.example"], hold: String? = "15"
    ) -> EmailSubmission.Envelope {
        EmailSubmission.Envelope(
            mailFrom: .init(email: from, parameters: hold.map { ["HOLDFOR": $0] }), rcptTo: to.map { .init(email: $0) })
    }

    func submit(_ email: EmailCreate? = nil, identity: String = "ident-1", envelope: EmailSubmission.Envelope? = nil)
        async throws -> SubmissionResult {
        try await client.submit(
            email ?? draft(), identityID: identity, envelope: envelope ?? self.envelope(), mailboxes: mailboxes)
    }

    func flags(_ id: String) async throws -> Email? {
        try await client.emails(ids: [id], properties: ["mailboxIds", "keywords"]).first
    }

    // MARK: Drafts

    @Test func draftSaveCreatesTheNewVersionAndDestroysTheOld() async throws {
        let first = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)

        let second = try await client.saveDraft(draft(subject: "Lunch?"), replacing: first)

        #expect(second.destroyedPrevious)
        #expect(!second.previousWasMissing)
        let id = try #require(second.createdID)
        #expect(try await flags(first) == nil)
        let saved = try #require(try await client.emails(ids: [id]).first)
        #expect(saved.subject == "Lunch?")
        #expect(saved.mailboxIds == ["drafts": true])
        #expect(saved.has(.draft) && saved.has(.seen))
        #expect(saved.messageId == ["lunch-1@fastmail.com"])
        #expect(saved.receivedAt == clock.now)
        #expect(saved.from == [EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")])
        #expect(saved.textBody?.map(\.partId) == ["text"])
        #expect(saved.htmlBody?.map(\.partId) == ["html"])
        #expect(saved.bodyValues?["html"]?.value == "<div>See you at noon</div>")
        #expect(saved.preview == "See you at noon")
        #expect(saved.attachments == [])
        #expect(saved.hasAttachment == false)
    }

    @Test func staleSaveFindsThePreviousVersionGone() async throws {
        let first = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)
        _ = try await client.saveDraft(draft(subject: "Saved on this device"), replacing: first)

        let stale = try await client.saveDraft(draft(subject: "Saved on another device"), replacing: first)

        #expect(stale.createdID != nil)
        #expect(stale.previousWasMissing)
        #expect(stale.destroyedPrevious)
    }

    @Test func replyJoinsTheConversationOfItsOriginal() async throws {
        let id = try #require(try await client.saveDraft(draft(inReplyTo: ["e3@demo"]), replacing: nil).createdID)
        let other = try #require(try await client.saveDraft(draft(messageID: "other@fastmail.com"), replacing: nil).createdID)

        let threads = try await client.emails(ids: [id, other], properties: ["threadId"]).map(\.threadId)
        #expect(threads.first == "t1")
        #expect(threads.last != "t1")
    }

    @Test func invalidDraftIsRefusedAndTheOldOneStillDestroyed() async throws {
        let first = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)
        var broken = draft()
        broken.bodyValues = [:]

        let result = try await client.saveDraft(broken, replacing: first)

        #expect(result.createdID == nil)
        #expect(result.createError == SetError(type: SetError.invalidProperties, properties: ["bodyStructure"]))
        #expect(result.destroyedPrevious)
        #expect(try await flags(first) == nil)
    }

    @Test func messageIDLookupFindsTheCopies() async throws {
        let id = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)

        let lookup = try await client.emails(withMessageID: "lunch-1@fastmail.com")

        #expect(lookup.filterWorked)
        #expect(lookup.matches.map(\.id) == [id])
        #expect(lookup.matches.first?.isDraft == true)
        #expect(lookup.matches.first?.receivedAt == clock.now)
        #expect(try await client.emails(withMessageID: "e3@demo").matches.map(\.id) == ["e3"])
        #expect(try await client.emails(withMessageID: "nowhere@fastmail.com").matches.isEmpty)
    }

    @Test func serverIgnoringTheHeaderFilterIsNoticedAndRecentMailFindsTheCopy() async throws {
        let id = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)
        server.ignoresHeaderFilter = true

        let lookup = try await client.emails(withMessageID: "lunch-1@fastmail.com")
        let recent = try await client.recentEmails(
            inMailboxes: [mailboxes.drafts, mailboxes.sent], after: clock.now.addingTimeInterval(-600), limit: 200)

        #expect(!lookup.filterWorked)
        #expect(lookup.matches.map(\.id) == [id])
        #expect(recent.map(\.id) == [id])
    }

    // MARK: Sending

    @Test func heldMessageGoesOutWhenItsHoldEnds() async throws {
        let before = try await client.emailPage(limit: 1).state

        let result = try await submit()

        let emailID = try #require(result.emailID)
        let submission = try #require(result.submission)
        #expect(submission.undoStatus == .pending)
        #expect(submission.sendAt == clock.now.addingTimeInterval(15))
        #expect(result.movedToSent)
        #expect(server.pendingSubmissionIDs == [submission.id])
        #expect(try await flags(emailID)?.mailboxIds == ["sent": true])
        #expect(try await flags(emailID)?.has(.draft) == false)
        #expect(try await client.submissions(forEmailIDs: [emailID]).map(\.id) == [submission.id])
        #expect(try await client.emailChanges(since: before).changed.map(\.id) == [emailID])

        server.advanceClock(by: 14)
        #expect(server.sentMessages.isEmpty)
        server.advanceClock(by: 2)

        #expect(server.pendingSubmissionIDs.isEmpty)
        #expect(server.sentMessages == [DemoSentMessage(
            submissionId: submission.id, emailId: emailID, identityId: "ident-1", from: "alex@fastmail.com",
            mailFrom: "alex@fastmail.com", rcptTo: ["maya@lindqvist.example"], subject: "Lunch",
            messageId: "lunch-1@fastmail.com", sentAt: Self.start.addingTimeInterval(16))])
        #expect(try await flags(emailID)?.mailboxIds == ["sent": true])
        #expect(try await flags(emailID)?.has(.draft) == false)
        let (found, notFound) = try await client.submissions(ids: [submission.id])
        #expect(found.isEmpty)
        #expect(notFound == [submission.id])
    }

    @Test func releaseLagsBehindSendAtByTheReleaseDelay() async throws {
        server.releaseDelay = 10
        let submission = try #require(try await submit().submission)

        server.advanceClock(by: 16)

        #expect(server.pendingSubmissionIDs == [submission.id])
        #expect(try await client.submissions(ids: [submission.id]).found.first?.undoStatus == .pending)
        server.advanceClock(by: 9)
        #expect(server.pendingSubmissionIDs.isEmpty)
        #expect(server.sentMessages.count == 1)
    }

    @Test func undoWithinTheHoldPutsTheMessageBackInDrafts() async throws {
        let result = try await submit()
        let submission = try #require(result.submission)
        server.advanceClock(by: 5)

        #expect(try await client.cancelSubmission(submission.id, mailboxes: mailboxes) == .canceled)

        let emailID = try #require(result.emailID)
        let email = try #require(try await flags(emailID))
        #expect(email.mailboxIds == ["drafts": true])
        #expect(email.has(.draft))
        #expect(server.pendingSubmissionIDs.isEmpty)
        server.advanceClock(by: 60)
        #expect(server.sentMessages.isEmpty)
    }

    @Test func undoAfterTheReleaseIsTooLate() async throws {
        let result = try await submit()
        server.advanceClock(by: 16)

        let submissionID = try #require(result.submission?.id)
        let emailID = try #require(result.emailID)
        #expect(try await client.cancelSubmission(submissionID, mailboxes: mailboxes) == .alreadySent)
        #expect(try await flags(emailID)?.mailboxIds == ["sent": true])
        #expect(server.sentMessages.count == 1)
    }

    @Test func lostResponseLeavesTheMessageSubmitted() async throws {
        server.loseNextResponse()

        let error = await #expect(throws: JMAPError.self) { try await submit() }

        #expect(error == .connection(.networkConnectionLost, URLError(.networkConnectionLost).localizedDescription))
        #expect(error?.mayHaveReachedServer == true)
        let copies = try await client.emails(withMessageID: "lunch-1@fastmail.com").matches
        #expect(copies.map(\.mailboxIds) == [["sent": true]])
        #expect(try await client.submissions(forEmailIDs: copies.map(\.id)).count == 1)
        server.advanceClock(by: 15)
        #expect(server.sentMessages.count == 1)
    }

    @Test func busyAnswerAfterTheWorkLeavesTheMessageSubmittedOnce() async throws {
        server.answerNext(withStatus: 503)

        let error = await #expect(throws: JMAPError.self) { try await submit() }

        #expect(error == .http(status: 503, problemType: nil))
        #expect(error?.mayHaveReachedServer == true)
        #expect(server.pendingSubmissionIDs.count == 1)
        server.advanceClock(by: 15)
        #expect(server.sentMessages.count == 1)
    }

    @Test func failedSubmissionCallLeavesTheEmailADraft() async throws {
        server.failNextSubmission(methodError: MethodError.serverUnavailable)

        let result = try await submit()

        #expect(result.submissionMethodError == MethodError(type: MethodError.serverUnavailable))
        #expect(result.submission == nil)
        let emailID = try #require(result.emailID)
        #expect(try await flags(emailID)?.mailboxIds == ["drafts": true])
        #expect(try await flags(emailID)?.has(.draft) == true)
        #expect(try await client.submissions(forEmailIDs: [emailID]).isEmpty)
        #expect(server.pendingSubmissionIDs.isEmpty)
        // The next submission is accepted again.
        #expect(try await submit(draft(messageID: "lunch-2@fastmail.com")).submission?.undoStatus == .pending)
    }

    @Test func refusedHoldIsAnInvalidEnvelope() async throws {
        server.rejectsHoldFor = true

        let held = try await submit()
        let immediate = try await submit(draft(messageID: "lunch-2@fastmail.com"), envelope: envelope(hold: nil))

        #expect(held.submissionError == SetError(type: SetError.invalidProperties, properties: ["envelope"]))
        let heldID = try #require(held.emailID)
        #expect(try await flags(heldID)?.has(.draft) == true)
        #expect(immediate.submission?.undoStatus == .final)
        #expect(server.sentMessages.map(\.messageId) == ["lunch-2@fastmail.com"])
    }

    @Test(arguments: ["15s", "", "-1", "100000000", "1.5"])
    func holdMustBeAStringOfDigits(hold: String) async throws {
        let result = try await submit(envelope: envelope(hold: hold))

        #expect(result.submissionError
            == SetError(type: SetError.invalidProperties, properties: ["envelope/mailFrom/parameters/HOLDFOR"]))
    }

    @Test func messageWithoutHoldGoesOutAtOnce() async throws {
        let result = try await submit(envelope: envelope(hold: nil))

        #expect(result.submission?.undoStatus == .final)
        #expect(result.submission?.sendAt == clock.now)
        #expect(server.pendingSubmissionIDs.isEmpty)
        #expect(server.sentMessages.count == 1)
    }

    @Test func messageToYourselfArrivesInTheInbox() async throws {
        let result = try await submit(
            draft(to: ["alex@fastmail.com"]), envelope: envelope(to: ["alex@fastmail.com", "maya@lindqvist.example"]))
        let before = try await client.emailPage(limit: 1).state
        server.advanceClock(by: 15)

        let arrived = try await client.emailChanges(since: before).changed.filter { $0.id != result.emailID }
        #expect(arrived.count == 1)
        let copy = try #require(try await client.emails(ids: arrived.map(\.id)).first)
        #expect(copy.mailboxIds == ["inbox": true])
        #expect(copy.keywords == [:])
        #expect(copy.messageId == ["lunch-1@fastmail.com"])
        #expect(copy.deliveredToAddresses == [EmailAddress(email: "alex@fastmail.com")])
    }

    @Test func expiredUploadIsNotFound() async throws {
        let bytes = Data("%PDF-1.4 expiring".utf8)
        let upload = try await client.upload(bytes, type: "application/pdf")
        let attachment = EmailBodyPartCreate.blob(upload.blobId, type: "application/pdf", name: "a.pdf", disposition: "attachment")
        server.expireUploads()

        let refused = try await client.saveDraft(draft(attachments: [attachment]), replacing: nil)
        let sendRefused = try await submit(draft(attachments: [attachment]))

        #expect(refused.createError == SetError(type: SetError.blobNotFound, notFound: [upload.blobId]))
        #expect(sendRefused.emailError == SetError(type: SetError.blobNotFound, notFound: [upload.blobId]))
        #expect(sendRefused.submissionError?.type == SetError.invalidProperties)
        #expect(server.pendingSubmissionIDs.isEmpty)

        let again = try await client.upload(bytes, type: "application/pdf")
        #expect(again.blobId == upload.blobId)
        #expect(try await submit(draft(attachments: [attachment])).submission?.undoStatus == .pending)
        #expect(server.uploadCount == 2)
    }

    @Test func uploadExpiresADayLaterUnlessAnEmailRefersToIt() async throws {
        let kept = try await client.upload(Data("kept".utf8), type: "text/plain")
        let dropped = try await client.upload(Data("dropped".utf8), type: "text/plain")
        #expect(kept.expires == clock.now.addingTimeInterval(86_400))
        let attachment = EmailBodyPartCreate.blob(kept.blobId, type: "text/plain", name: "kept.txt", disposition: "attachment")
        let id = try #require(try await client.saveDraft(draft(attachments: [attachment]), replacing: nil).createdID)

        server.advanceClock(by: 86_401)
        server.expireUploads()

        #expect(try await client.download(blobId: kept.blobId, type: "text/plain", name: "kept.txt") == Data("kept".utf8))
        await #expect(throws: JMAPError.http(status: 404, problemType: nil)) {
            try await client.download(blobId: dropped.blobId, type: "text/plain", name: "dropped.txt")
        }
        let saved = try #require(try await client.emails(ids: [id]).first)
        #expect(saved.attachments?.map(\.blobId) == [kept.blobId])
        #expect(saved.attachments?.first?.size == 4)
        #expect(saved.hasAttachment == true)
    }

    // MARK: Identities and senders

    @Test func identitiesAreTheLoginAndAWildcardDomain() async throws {
        #expect(try await client.identities() == [
            Identity(id: "ident-1", name: "Alex Berg", email: "alex@fastmail.com", textSignature: "-- \nAlex",
                     htmlSignature: "<div>Alex</div>", mayDelete: false),
            Identity(id: "ident-2", name: "Alex Berg", email: "*@berg.example", textSignature: "", htmlSignature: "",
                     mayDelete: true),
        ])
    }

    @Test func maskedFromNeedsAnIdentityOfItsOwn() async throws {
        let masked = draft(from: "fjord.k3x9@fastmail.com", name: nil)
        let maskedEnvelope = envelope(from: "fjord.k3x9@fastmail.com")

        let refused = try await submit(masked, envelope: maskedEnvelope)
        let identity = try await client.createIdentity(.init(email: "fjord.k3x9@fastmail.com"))
        let sent = try await submit(draft(from: "fjord.k3x9@fastmail.com", name: nil, messageID: "m2@fastmail.com"),
                                    identity: identity.id, envelope: maskedEnvelope)
        server.advanceClock(by: 15)

        #expect(refused.submissionError?.type == SetError.forbiddenFrom)
        #expect(identity == Identity(id: identity.id, email: "fjord.k3x9@fastmail.com", mayDelete: true))
        #expect(try await client.identities().map(\.email) == ["alex@fastmail.com", "*@berg.example", "fjord.k3x9@fastmail.com"])
        #expect(sent.submission?.undoStatus == .pending)
        #expect(server.sentMessages.map(\.from) == ["fjord.k3x9@fastmail.com"])
        #expect(server.sentMessages.map(\.mailFrom) == ["fjord.k3x9@fastmail.com"])
    }

    @Test(arguments: ["win.a7b2@fastmail.com", "someone@elsewhere.example", "alex@fastmail.com", "shop@berg.example"])
    func identitiesAreOnlyMadeForEnabledMaskedAddresses(address: String) async throws {
        await #expect(throws: SetError.self) { try await client.createIdentity(.init(email: address)) }
    }

    @Test func lenientServerLetsAnyIdentitySendFromAMask() async throws {
        server.requiresIdentityForMaskedFrom = false

        let result = try await submit(draft(from: "fjord.k3x9@fastmail.com", name: nil),
                                      envelope: envelope(from: "fjord.k3x9@fastmail.com"))

        #expect(result.submission?.undoStatus == .pending)
        #expect(result.submissionError == nil)
    }

    @Test func wildcardIdentitySendsFromAnyAddressAtItsDomain() async throws {
        server.deliver(id: "shop1", threadId: "tShop", from: "Shop", subject: "Your order", text: "Thanks!",
                       toAddress: "shop@berg.example", deliveredTo: "shop@berg.example")
        let reply = draft(from: "shop@berg.example", inReplyTo: ["shop1@demo"])

        let underDefault = try await submit(reply, envelope: envelope(from: "shop@berg.example"))
        let underWildcard = try await submit(reply, identity: "ident-2", envelope: envelope(from: "shop@berg.example"))

        let delivered = try #require(try await client.emails(ids: ["shop1"]).first)
        #expect(delivered.to == [EmailAddress(email: "shop@berg.example")])
        #expect(delivered.deliveredToAddresses == [EmailAddress(email: "shop@berg.example")])
        #expect(underDefault.submissionError?.type == SetError.forbiddenFrom)
        #expect(underWildcard.submission?.undoStatus == .pending)
    }

    @Test func envelopeMustComeFromTheSender() async throws {
        let result = try await submit(envelope: envelope(from: "other@fastmail.com"))

        #expect(result.submissionError?.type == SetError.forbiddenMailFrom)
    }

    @Test func recipientsAreChecked() async throws {
        let none = try await submit(envelope: envelope(to: []))
        let invalid = try await submit(envelope: envelope(to: ["maya@lindqvist.example", "not an address"]))
        server.rejectNextSubmission(SetError(type: SetError.tooLarge, maxSize: 1000))
        let tooLarge = try await submit()
        let unknownIdentity = try await submit(identity: "ident-9")

        #expect(none.submissionError == SetError(type: SetError.noRecipients))
        #expect(invalid.submissionError == SetError(type: SetError.invalidRecipients, invalidRecipients: ["not an address"]))
        #expect(tooLarge.submissionError == SetError(type: SetError.tooLarge, maxSize: 1000))
        #expect(unknownIdentity.submissionError == SetError(type: SetError.invalidProperties, properties: ["identityId"]))
        #expect(server.pendingSubmissionIDs.isEmpty)
    }

    @Test func tokenWithoutSubmissionCanStillSaveDrafts() async throws {
        let server = DemoTransport(clock: clock, supportsSubmission: false)
        let client = JMAPClient(token: "demo", transport: server, maxRetries: 0)

        let session = try await client.session()
        let saved = try await client.saveDraft(draft(), replacing: nil)
        var batch = Batch()
        batch.add(IdentityGet(accountId: "demo"))
        let error = await #expect(throws: JMAPError.self) { try await client.send(batch) }

        #expect(!session.canSubmit)
        #expect(!session.supports(Capability.submission))
        #expect(saved.createdID != nil)
        #expect(error == .http(status: 403, problemType: "urn:ietf:params:jmap:error:unknownCapability"))
        #expect(error?.mayHaveReachedServer == false)
        await #expect(throws: JMAPError.missingCapability(Capability.submission)) {
            try await client.submit(draft(), identityID: "ident-1", envelope: envelope(), mailboxes: mailboxes)
        }

        // A token with the scope: the client notices the session changed with the next answer.
        server.supportsSubmission = true
        _ = try await client.mailboxes()
        #expect(try await client.session().canSubmit)
    }

    // MARK: Another device

    @Test func messageSentFromAnotherDeviceShowsUpInSent() async throws {
        let draftID = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)
        let before = try await client.emailPage(limit: 1).state

        server.sendFromAnotherDevice(messageID: "lunch-1@fastmail.com", subject: "Lunch")

        let copies = try await client.emails(withMessageID: "lunch-1@fastmail.com").matches
        let sent = try #require(copies.first { !$0.isDraft })
        #expect(copies.count == 2)
        #expect(sent.mailboxIds == ["sent": true])
        #expect(copies.contains { $0.id == draftID && $0.isDraft })
        #expect(try await client.emailChanges(since: before).changed.map(\.id) == [sent.id])
        #expect(server.sentMessages.isEmpty)
    }

    @Test func draftEditedOnAnotherDeviceIsReplaced() async throws {
        let draftID = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)

        let newID = try #require(server.editDraftOnAnotherDevice(emailID: draftID))

        let edited = try #require(try await client.emails(ids: [newID]).first)
        #expect(try await flags(draftID) == nil)
        #expect(edited.messageId == ["lunch-1@fastmail.com"])
        #expect(edited.has(.draft))
        #expect(edited.bodyValues?["text"]?.value.hasSuffix("Changed on another device.") == true)
        #expect(edited.bodyValues?["html"]?.value.hasSuffix("<div>Changed on another device.</div>") == true)
        #expect(try await client.saveDraft(draft(), replacing: draftID).previousWasMissing)
        #expect(server.editDraftOnAnotherDevice(emailID: "missing") == nil)
    }

    @Test func draftMovedToTrashOnAnotherDevice() async throws {
        let draftID = try #require(try await client.saveDraft(draft(), replacing: nil).createdID)

        server.moveToTrash(emailID: draftID)

        #expect(try await flags(draftID)?.mailboxIds == ["trash": true])
        #expect(try await client.emails(withMessageID: "lunch-1@fastmail.com").matches.first?.mailboxIds == ["trash": true])
    }

    // MARK: Push

    @Test func pushTellsOfSubmissionsAndIdentities() async throws {
        var events = client.pushEvents(types: ["EmailSubmission", "Identity"], ping: 0).makeAsyncIterator()
        #expect(try await events.next() == .connected)

        _ = try await submit()
        let submitted = try await events.next()
        _ = try await client.createIdentity(.init(email: "fjord.k3x9@fastmail.com"))
        let identity = try await events.next()

        guard case .stateChange(let submissionChange)? = submitted, case .stateChange(let identityChange)? = identity else {
            Issue.record("Expected two state changes, got \(String(describing: submitted)), \(String(describing: identity))")
            return
        }
        #expect(submissionChange.changed["demo"]?.keys.sorted() == ["EmailSubmission"])
        #expect(identityChange.changed["demo"]?.keys.sorted() == ["Identity"])
    }
}
