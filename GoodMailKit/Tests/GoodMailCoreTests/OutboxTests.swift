import DemoAccount
import Foundation
import JMAPKit
import MailCompose
import MailStore
import Testing
@testable import GoodMailCore

/// Sending through the outbox against the demo account on a manual clock: Fastmail holds each message 15 s,
/// Undo cancels it, and the outbox finishes once the hold has passed (§2.2, D12–D14).
@MainActor
struct OutboxTests {
    let account: OutboxTestAccount
    var model: MailModel { account.model }
    var outbox: Outbox { account.outbox }
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

    // MARK: Undo

    @Test func sendIsHeldAndUndoBringsTheComposerBack() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let id = composer.id
        let start = account.clock.now

        try await composer.send()
        #expect(await model.composer(id: id) == nil)
        await account.settle()

        let row = try #require(try await account.row(id))
        #expect(row.state == .held)
        let submission = try #require(row.record.submission)
        #expect(submission.submittedAt == start)
        #expect(outbox.items.map(\.state) == [.held(undoUntil: start + 10, sendsAround: start + 15)])
        #expect(outbox.undoable == Outbox.UndoableSend(id: id, subject: "Lunch", undoUntil: start + 10))
        #expect(account.server.pendingSubmissionIDs == [submission.id])
        guard case .object(let call)? = account.transport.arguments(of: "EmailSubmission/set").last else {
            Issue.record("No submission")
            return
        }
        #expect(call["create"]?.at("s", "envelope", "mailFrom") == [
            "email": "alex@fastmail.com", "parameters": ["HOLDFOR": "15"],
        ])
        #expect(call["create"]?.at("s", "envelope", "rcptTo") == [["email": "maya@lindqvist.example", "parameters": nil]])

        await account.advance(5)
        #expect(outbox.undoable != nil)
        #expect(await outbox.cancel(id) == .backToDrafts)

        #expect(account.server.pendingSubmissionIDs.isEmpty)
        let restored = try #require(await model.composer(id: id))
        #expect(restored.to == [maya] && restored.subject == "Lunch")
        #expect(String(restored.body.characters) == "See you at noon")
        let back = try #require(try await account.row(id))
        #expect(back.state == .editing && !back.hasUnsyncedChanges)
        let backID = try #require(back.serverEmailID)
        let copy = try #require(try await account.serverEmail(backID))
        #expect(copy.mailboxIds == ["drafts": true] && copy.has(.draft))
        #expect(outbox.items.isEmpty && outbox.undoable == nil)

        await account.advance(20)
        #expect(account.server.sentMessages.isEmpty)
    }

    @Test func sentMessageIsFinalizedOnceTheHoldHasPassed() async throws {
        await account.start()
        let composer = try await model.compose(.reply(emailID: "e3", all: false))
        composer.body = AttributedString("Will do!")
        try await composer.addAttachment(Data("Early check-in, please".utf8), name: "Notes.txt", typeIdentifier: "public.plain-text")
        await composer.saveNow()
        let id = composer.id
        let previous = try #require(try await account.row(id)?.serverEmailID)
        let attachmentID = try #require(composer.attachments.first?.id)

        try await composer.send()
        await account.settle()

        #expect(try await account.row(id)?.state == .held)
        // The earlier version goes once the submission exists (D33).
        #expect(try await account.serverEmail(previous) == nil)
        #expect(account.server.sentMessages.isEmpty)

        await account.advance(17)

        #expect(try await account.row(id) == nil)
        #expect(try await account.store.outgoingAttachments(draftID: id.uuidString).isEmpty)
        await #expect(throws: MailStoreError.self) {
            try await account.store.outgoingAttachmentData(id: attachmentID.uuidString)
        }
        let sent = try #require(account.server.sentMessages.only)
        #expect(sent.rcptTo == ["maya@lindqvist.example"] && sent.subject == "Re: Trip to Lisbon")
        let copy = try #require(try await account.serverEmail(sent.emailId))
        #expect(copy.mailboxIds == ["sent": true] && !copy.has(.draft))
        #expect(copy.attachments?.map(\.name) == ["Notes.txt"])
        #expect(try await account.serverEmail("e3")?.has(.answered) == true)
        #expect(outbox.items.isEmpty && outbox.undoable == nil && !outbox.hasPendingWork)
    }

    @Test func aSlowReleaseIsCheckedAgainAndNeverFinalizedEarly() async throws {
        await account.start()
        account.server.releaseDelay = 10
        let composer = try await account.composeToMaya()
        try await composer.send()
        await account.settle()
        let id = composer.id

        await account.advance(17)
        #expect(try await account.row(id)?.state == .held)
        #expect(try await account.record(id)?.submission?.checks == 1)
        #expect(try await account.record(id)?.submission?.nextCheckAt == account.clock.now + 5)

        await account.advance(5)
        #expect(try await account.row(id)?.state == .held)
        #expect(account.server.sentMessages.isEmpty)

        await account.advance(5)
        #expect(try await account.row(id) == nil)
        #expect(account.server.sentMessages.count == 1)
    }

    // MARK: Waiting

    @Test func offlineSendWaitsUntilTheNetworkIsBackAndCanBeCancelled() async throws {
        await account.start()
        account.server.isOffline = true
        await account.setOnline(false)
        let first = try await account.composeToMaya()
        try await first.send()
        await account.settle()

        #expect(try await account.row(first.id)?.state == .queued)
        #expect(outbox.items.map(\.state) == [.waiting(.offline)])
        #expect(outbox.undoable == nil)
        #expect(await outbox.cancel(first.id) == .backToDrafts)
        #expect(try await account.row(first.id)?.state == .editing)

        let second = try await account.composeToMaya(subject: "Dinner")
        try await second.send()
        account.server.isOffline = false
        await account.setOnline(true)
        #expect(try await eventually { try await account.row(second.id)?.state == .held })
        #expect(account.transport.calls(to: "EmailSubmission/set") == 1)
    }

    @Test func requestsFailingWithoutAConnectionNeverShowAsSending() async throws {
        await account.start()
        account.server.isOffline = true
        let composer = try await account.composeToMaya()
        try await composer.send()
        await account.settle()

        #expect(try await account.row(composer.id)?.state == .queued)
        #expect(try await account.record(composer.id)?.wait == .connection)
        #expect(outbox.items.map(\.state) == [.waiting(.offline)])
        #expect(account.transport.calls(to: "EmailSubmission/set") == 0)

        account.server.isOffline = false
        await account.advance(30)
        #expect(try await account.row(composer.id)?.state == .held)
    }

    @Test func coldStartOfflineSendsWithTheKnownIdentity() async throws {
        await account.start()
        account.server.isOffline = true
        await account.setOnline(false)
        let model = account.relaunch()
        await model.start()

        #expect(model.username == "alex@fastmail.com")
        #expect(model.sendAvailability == .available)
        #expect(model.identities.map(\.id) == ["ident-1", "ident-2"])
        let composer = try await model.compose(.new(to: [maya], subject: "Offline", body: AttributedString("Queued")))
        #expect(composer.from == EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"))
        #expect(composer.signature == Signature(html: "<div>Alex</div>", text: "-- \nAlex"))
        try await composer.send()
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .queued)

        account.server.isOffline = false
        await account.setOnline(true)
        #expect(try await eventually { try await account.row(composer.id)?.state == .held })
        await account.advance(17)
        #expect(account.server.sentMessages.only?.identityId == "ident-1")
        #expect(account.server.sentMessages.only?.from == "alex@fastmail.com")
    }

    @Test func aRefreshNeverWaitsForUploads() async throws {
        await account.start()
        account.transport.hold(OutboxTestTransport.upload)
        let composer = try await account.composeToMaya()
        try await composer.addAttachment(Data(repeating: 7, count: 4096), name: "Plan.bin", typeIdentifier: "public.data")
        try await composer.send()

        await model.refresh()

        #expect(account.transport.heldRequests == 1)
        #expect(outbox.uploadProgress(for: composer.id) == 0)
        #expect(try await account.row(composer.id)?.state == .queued)
        #expect(outbox.items.first.map { item in
            if case .waiting(.uploading) = item.state { true } else { false }
        } == true)
        account.transport.release(OutboxTestTransport.upload)
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .held)
        #expect(outbox.uploadProgress(for: composer.id) == nil)
    }

    @Test func discardingAWaitingMessageMovesItsDraftToTrash() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        let copy = try #require(try await account.row(composer.id)?.serverEmailID)
        account.server.isOffline = true
        try await composer.send()
        await account.flushed()
        #expect(outbox.items.map(\.state) == [.waiting(.offline)])

        #expect(await outbox.discard(composer.id) == .discarded)

        #expect(try await account.row(composer.id) == nil)
        #expect(outbox.items.isEmpty)
        account.server.isOffline = false
        await model.refresh()
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["trash": true])
        await account.advance(60)
        #expect(account.server.sentMessages.isEmpty)
    }

    // MARK: Without a composer (App Intents)

    @Test func theOutboxSavesAndSendsDraftsDirectly() async throws {
        await account.start()
        let draft = MessageDraft(
            from: EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"), to: [maya], subject: "From Shortcuts",
            body: AttributedString("Hi Maya"))

        try await outbox.save(draft, toServer: true)
        let copy = try #require(try await account.row(draft.id)?.serverEmailID)
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["drafts": true])

        try await outbox.send(draft)
        await account.settle()

        #expect(try await account.row(draft.id)?.state == .held)
        #expect(try await account.serverEmail(copy) == nil)
        await account.advance(17)
        let sent = try #require(account.server.sentMessages.only)
        let text = try await account.serverEmail(sent.emailId)?.bodyValues?["text"]?.value
        #expect(text == "Hi Maya\n\n-- \nAlex")
        await #expect(throws: SendProblem.noRecipients) {
            try await outbox.send(MessageDraft(from: EmailAddress(email: "alex@fastmail.com"), subject: "Nobody"))
        }
    }

    @Test func savingAMessageOnItsWayToFastmailLeavesItAlone() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        let draft = composer.draft
        account.server.advanceClock(by: 1)
        try await composer.send()
        await account.settle()
        // The synced store now has the held message in Sent, where no draft is.
        account.server.advanceClock(by: 1)
        await model.refresh()
        let calls = ["Email/set", "Email/query"].map { account.transport.calls(to: $0) }

        try await outbox.save(draft, toServer: true)

        #expect(try await account.row(composer.id)?.state == .held)
        #expect(["Email/set", "Email/query"].map { account.transport.calls(to: $0) } == calls)
        #expect(await outbox.cancel(composer.id) == .backToDrafts)
        await account.advance(20)
        #expect(account.server.sentMessages.isEmpty)
    }

    // MARK: The token (D18)

    @Test func replacingTheTokenKeepsDraftsAndLearnsWhatTheNewOneMay() async throws {
        let account = try OutboxTestAccount(supportsSubmission: false)
        await account.start()
        let model = account.model
        #expect(model.sendAvailability == .tokenLacksSubmission)
        let composer = try await account.composeToMaya()
        await composer.saveNow()
        #expect(composer.problems == [.cannotSend(.tokenLacksSubmission)])

        account.server.supportsSubmission = true
        await model.client.setToken("new token")
        await model.tokenChanged()

        #expect(model.sendAvailability == .available)
        #expect(model.identities.map(\.id) == ["ident-1", "ident-2"])
        #expect(composer.problems.isEmpty)
        try await composer.send()
        await account.settle()
        #expect(try await account.row(composer.id)?.state == .held)
    }

    // MARK: Push, background, sign-out

    @Test func pushAsksForSubmissionsAndIdentitiesOnlyWhenTheTokenMaySend() async throws {
        let model = account.relaunch(syncsInBackground: true)
        await model.start()
        #expect(await eventually { model.isPushConnected })
        let types = try #require(account.transport.eventSourceURLs.last.flatMap(Self.types))
        #expect(types.isSuperset(of: ["Email", "Mailbox", "Thread", "EmailDelivery", "MaskedEmail", "EmailSubmission", "Identity"]))

        let withoutSubmission = try OutboxTestAccount(supportsSubmission: false)
        let other = withoutSubmission.relaunch(syncsInBackground: true)
        await other.start()
        #expect(await eventually { other.isPushConnected })
        let otherTypes = try #require(withoutSubmission.transport.eventSourceURLs.last.flatMap(Self.types))
        #expect(!otherTypes.contains("EmailSubmission") && !otherTypes.contains("Identity"))
        #expect(otherTypes.contains("Email"))
        other.stop()
        model.stop()
    }

    @Test func identitiesChangedElsewhereArePushedAndReadAgain() async throws {
        let model = account.relaunch(syncsInBackground: true)
        await model.start()
        #expect(await eventually { model.isPushConnected })
        #expect(model.senderOptions().first { $0.address.email == "fjord.k3x9@fastmail.com" }?.needsSendingIdentity == true)

        _ = try await account.client.createIdentity(Identity.Create(email: "fjord.k3x9@fastmail.com"))

        #expect(await eventually { model.identities.contains { $0.email == "fjord.k3x9@fastmail.com" } })
        #expect(model.senderOptions().first { $0.address.email == "fjord.k3x9@fastmail.com" }?.needsSendingIdentity == false)
        let stored = try #require(try await account.store.keyedData("account"))
        #expect(try JSONDecoder().decode(AccountSnapshot.self, from: stored).identities.count == 3)
        model.stop()
    }

    private static func types(of url: URL) -> Set<String>? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "types" }?.value
        return value.map { Set($0.split(separator: ",").map(String.init)) }
    }

    @Test func backgroundTasksSendWithoutTheViewsHavingStartedAnything() async throws {
        await account.start()
        account.server.isOffline = true
        let composer = try await account.composeToMaya()
        try await composer.send()
        await account.settle()
        account.server.isOffline = false
        let model = account.relaunch()

        let remains = await model.sendPendingMail()

        #expect(remains)
        #expect(try await account.row(composer.id)?.state == .held)
        account.server.advanceClock(by: 17)
        #expect(await model.sendPendingMail() == false)
        #expect(account.server.sentMessages.count == 1)
    }

    @Test func goingToTheBackgroundSavesOpenComposersToFastmail() async throws {
        await account.start()
        let composer = try await account.composeToMaya()

        await model.prepareForBackground()

        #expect(try await account.row(composer.id)?.serverEmailID != nil)
        #expect(composer.saveStatus == .savedToServer(account.clock.now))
    }

    @Test func signOutSummaryCountsWhatWouldBeLost() async throws {
        await account.start()
        #expect(await model.unsentSummary().isEmpty)
        let held = try await account.composeToMaya(subject: "Held")
        try await held.send()
        await account.settle()
        let local = try await account.composeToMaya(subject: "Local")
        await local.close()
        await account.outbox.waitUntilIdle()
        account.server.isOffline = true
        let waiting = try await account.composeToMaya(subject: "Waiting")
        try await waiting.send()
        let unsaved = try await account.composeToMaya(subject: "Unsaved")
        await unsaved.close()
        await account.settle()

        #expect(await model.unsentSummary() == UnsentSummary(waiting: 1, sending: 1, failed: 0, localOnlyDrafts: 1))
        #expect(outbox.unsyncedDrafts.map(\.subject) == ["Unsaved"])
        #expect(outbox.hasPendingWork)
    }
}

extension Array {
    /// The only element, or `nil` if there are none or several.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}

private extension JSONValue {
    /// The value at a path of object keys.
    func at(_ keys: String...) -> JSONValue? {
        keys.reduce(Optional(self)) { value, key in
            if case .object(let object)? = value { object[key] } else { nil }
        }
    }
}
