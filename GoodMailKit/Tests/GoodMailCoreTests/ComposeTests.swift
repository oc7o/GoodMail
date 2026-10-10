import CoreGraphics
import DemoAccount
import Foundation
import ImageIO
import JMAPKit
import MailCompose
import MailPrivacy
import MailStore
import Testing
@testable import GoodMailCore

/// Composing against the demo account: what a new message, a reply or a forward starts with, and how drafts
/// are saved on the device and to Fastmail.
@MainActor
struct ComposeTests {
    let account: OutboxTestAccount
    var model: MailModel { account.model }
    let maya = EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")

    init() throws {
        account = try OutboxTestAccount()
    }

    /// Waits for work that runs in its own task, such as an autosave, without sleeping.
    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0..<50_000 {
            if try await condition() { return true }
            await Task.yield()
        }
        return try await condition()
    }

    // MARK: Drafts

    @Test func newMessageIsSavedHereThenToDraftsReplacingItsPreviousCopyInOneCall() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        #expect(try await account.row(composer.id) == nil)
        #expect(composer.saveStatus == .unsaved)

        await composer.saveNow()

        let row = try #require(try await account.row(composer.id))
        let first = try #require(row.serverEmailID)
        #expect(row.serverRevision == row.revision)
        #expect(composer.saveStatus == .savedToServer(account.clock.now))
        let saved = try #require(try await account.serverEmail(first))
        #expect(saved.mailboxIds == ["drafts": true])
        #expect(saved.has(.draft) && saved.has(.seen))
        #expect(saved.messageId == [composer.draft.messageID])
        #expect(saved.from == [EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")])
        #expect(saved.to == [maya])
        #expect(saved.sentAt == account.clock.now)
        let html = try #require(saved.bodyValues?["html"]?.value)
        #expect(html.contains("<div>See you at noon</div>") && html.contains("<div class=\"signature\"><div>Alex</div></div>"))
        #expect(saved.bodyValues?["text"]?.value == "See you at noon\n\n-- \nAlex")

        composer.body = AttributedString("See you at one")
        await composer.saveNow()

        let second = try #require(try await account.row(composer.id)?.serverEmailID)
        #expect(second != first)
        #expect(try await account.serverEmail(first) == nil)
        let sets = account.transport.arguments(of: "Email/set")
        #expect(sets.count == 2)
        guard case .object(let replacing)? = sets.last else { return }
        #expect(replacing["destroy"] == [.string(first)])
        #expect(replacing["create"]?.objectKeys == ["d"])
    }

    @Test func typingIsSavedHereAfterASecondAndOnFastmailAfterFive() async throws {
        await account.start()
        let composer = try await account.composeToMaya()

        account.server.advanceClock(by: 1)
        #expect(await eventually { composer.saveStatus == .savedLocally })
        #expect(try await account.row(composer.id) != nil)
        #expect(try await account.row(composer.id)?.serverEmailID == nil)

        account.server.advanceClock(by: 4)
        #expect(try await eventually { try await account.row(composer.id)?.serverEmailID != nil })
        await account.outbox.waitUntilIdle()
        #expect(composer.saveStatus == .savedToServer(account.clock.now))
    }

    @Test func openingADraftWritesNothingUntilTheFirstEdit() async throws {
        await account.start()
        let opened = try await model.compose(.draft(emailID: "e15"))
        #expect(opened.mode == .editing)
        #expect(opened.subject == "Early check-in on 3 November?")
        #expect(String(opened.body.characters) == "Hello, we land at 11:40 on the 3rd. Would it be possible to")
        #expect(opened.signature == nil)

        await opened.close()
        await account.settle()
        #expect(try await account.row(opened.id) == nil)
        #expect(account.transport.calls(to: "Email/set") == 0)
        #expect(try await account.serverEmail("e15") != nil)

        let edited = try await model.compose(.draft(emailID: "e15"))
        edited.body = AttributedString("Hello, we land at 11:40 on the 3rd. Could we check in early?")
        await edited.saveNow()

        let row = try #require(try await account.row(edited.id))
        #expect(row.serverEmailID != nil && row.serverEmailID != "e15")
        #expect(try await account.serverEmail("e15") == nil)
        #expect(try await account.serverEmail(row.serverEmailID!)?.messageId == ["e15@demo"])
        // Its own row now answers for it.
        #expect(try await model.compose(.draft(emailID: row.serverEmailID!)) === edited)
    }

    @Test func closingAnEmptyNewMessageLeavesNothingBehind() async throws {
        await account.start()
        let composer = try await model.compose(.new())
        composer.subject = "Draft"
        await composer.saveNow()
        let copy = try #require(try await account.row(composer.id)?.serverEmailID)
        composer.subject = " "

        await composer.close()
        await account.settle()

        #expect(try await account.row(composer.id) == nil)
        #expect(try await account.serverEmail(copy)?.mailboxIds == ["trash": true])
        #expect(await model.composer(id: composer.id) == nil)
    }

    @Test func closingKeepsTheDraftAndSavesItToFastmail() async throws {
        await account.start()
        let composer = try await account.composeToMaya()

        await composer.close()
        await account.settle()

        let row = try #require(try await account.row(composer.id))
        #expect(row.state == .editing && !row.hasUnsyncedChanges)
        let restored = try #require(await model.composer(id: composer.id))
        #expect(restored !== composer)
        #expect(restored.to == [maya] && restored.subject == "Lunch")
        #expect(String(restored.body.characters) == "See you at noon")
        #expect(restored.saveStatus == .savedToServer(account.clock.now))
    }

    // MARK: Replies

    @Test func replyToTheNewsletterComesFromItsMaskWithoutNameOrSignature() async throws {
        await account.start()

        let composer = try await model.compose(.reply(emailID: "e4", all: false))

        #expect(composer.from == EmailAddress(email: "fjord.k3x9@fastmail.com"))
        #expect(composer.signature == nil)
        #expect(composer.to == [EmailAddress(name: "Fjord Outdoor", email: "news@fjord-outdoor.example")])
        #expect(composer.subject == "Re: Autumn layers are here")
        #expect(composer.draft.inReplyTo == ["e4@demo"])
        #expect(composer.draft.references == ["e4@demo"])
        #expect(composer.draft.messageIDDomain == "fastmail.com")
        #expect(composer.quote?.fromEmail == "news@fjord-outdoor.example")
        #expect(composer.senderWarning == nil)
        #expect(composer.notices.isEmpty)

        composer.from = EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")
        #expect(composer.senderWarning == "You received this at fjord.k3x9@fastmail.com. Sending from alex@fastmail.com "
            + "shows alex@fastmail.com to the recipients.")
    }

    @Test func replyToMayaComesFromTheLoginIdentityWithItsSignature() async throws {
        await account.start()

        let composer = try await model.compose(.reply(emailID: "e3", all: true))

        #expect(composer.from == EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"))
        #expect(composer.signature == Signature(html: "<div>Alex</div>", text: "-- \nAlex"))
        #expect(composer.to == [maya])
        #expect(composer.cc.isEmpty)
        #expect(composer.draft.references == ["e3@demo"])
        #expect(composer.kind == .replyAll)
    }

    @Test func replyFromADisabledMaskWarns() async throws {
        await account.start()
        await model.setMaskedEmailState(.disabled, id: "masked-1")

        let composer = try await model.compose(.reply(emailID: "e4", all: false))

        #expect(composer.from == EmailAddress(email: "fjord.k3x9@fastmail.com"))
        #expect(composer.senderWarning == "fjord.k3x9@fastmail.com is disabled, so replies to it go to Trash.")
    }

    @Test func mailToTheWildcardDomainIsAnsweredFromThatAddress() async throws {
        await account.start()
        account.server.deliver(
            id: "w1", threadId: "tw", from: "Jonas", subject: "Order 7", text: "Shipped.", toAddress: "shop@berg.example")
        await model.refresh()

        let composer = try await model.compose(.reply(emailID: "w1", all: true))

        #expect(composer.from == EmailAddress(name: "Alex Berg", email: "shop@berg.example"))
        #expect(composer.to == [EmailAddress(name: "Jonas", email: "jonas@example.com")])
        #expect(composer.cc.isEmpty)
        #expect(composer.draft.messageIDDomain == "berg.example")
    }

    @Test func aReplyToMailSentFromAMaskStaysOnTheMask() async throws {
        await account.start()
        account.outbox.maskedSending.createsIdentities = true
        let first = try await account.composeToMaya(subject: "Returns", text: "Can I return the jacket?")
        first.from = EmailAddress(email: "fjord.k3x9@fastmail.com")
        try await first.send(consentingToSendingIdentityFor: "fjord.k3x9@fastmail.com")
        await account.settle()
        await account.advance(17)
        await model.refresh()
        let sent = try #require(account.server.sentMessages.last)
        #expect(sent.from == "fjord.k3x9@fastmail.com")

        let reply = try await model.compose(.reply(emailID: sent.emailId, all: false))

        #expect(reply.from == EmailAddress(email: "fjord.k3x9@fastmail.com"))
        #expect(reply.to == [maya])
        #expect(reply.subject == "Re: Returns")
    }

    @Test func changingFromToAnotherDomainChangesTheMessageID() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let first = composer.draft.messageID
        #expect(composer.draft.messageIDDomain == "fastmail.com")

        composer.from = EmailAddress(email: "fjord.k3x9@fastmail.com")
        #expect(composer.draft.messageID == first)
        composer.from = EmailAddress(name: "Alex Berg", email: "shop@berg.example")
        #expect(composer.draft.messageIDDomain == "berg.example")

        try await composer.send()
        await account.settle()
        await account.advance(17)

        let sent = try #require(account.server.sentMessages.last)
        #expect(sent.from == "shop@berg.example" && sent.mailFrom == "shop@berg.example")
        #expect(sent.messageId?.hasSuffix("@berg.example") == true)
        #expect(sent.messageId != first)
    }

    @Test func aRestoredDraftLeavesItsIdentitysBccBehindOnAMask() async throws {
        await account.start()
        let archive = EmailAddress(email: "archive@berg.example")
        let boss = EmailAddress(email: "boss@berg.example")
        await model.outboxCreatedIdentity(Identity(
            id: "ident-9", name: "Alex Work", email: "work@berg.example", bcc: [archive], mayDelete: true))
        let composer = try await model.compose(.new(to: [maya], subject: "Hi", from: EmailAddress(email: "work@berg.example")))
        composer.bcc.append(boss)
        #expect(composer.bcc == [archive, boss])
        await composer.close()
        await account.settle()

        let restored = try #require(await model.composer(id: composer.id))
        #expect(restored.bcc == [archive, boss])
        restored.from = EmailAddress(email: "fjord.k3x9@fastmail.com")
        #expect(restored.bcc == [boss])
        restored.from = EmailAddress(name: "Alex Work", email: "work@berg.example")
        #expect(restored.bcc == [boss, archive])
    }

    @Test func mailtoLinkInTheNewsletterIsAnsweredFromItsMask() async throws {
        await account.start()
        let url = try #require(URL(string: "mailto:unsubscribe@fjord-outdoor.example?subject=unsubscribe%208f2a11&cc=x@y.example"))
        let link = try #require(MailtoLink(url))

        let fromMessage = try await model.compose(.mailto(link, sourceEmailID: "e4"))
        let fromNowhere = try await model.compose(.mailto(link, sourceEmailID: nil))

        #expect(fromMessage.from == EmailAddress(email: "fjord.k3x9@fastmail.com"))
        #expect(fromMessage.to == [EmailAddress(email: "unsubscribe@fjord-outdoor.example")])
        #expect(fromMessage.cc.isEmpty)
        #expect(fromMessage.subject == "unsubscribe 8f2a11")
        #expect(fromNowhere.from == EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"))
    }

    // MARK: Forwards

    @Test func forwardSendsTheOriginalsFilesByBlobWithoutDownloadingThem() async throws {
        await account.start()
        let composer = try await model.compose(.forward(emailID: "e5", asAttachment: false))
        #expect(composer.subject == "Fwd: Invoice 2041 for September")
        #expect(composer.attachments.map(\.source) == [.server(blobId: "e5-file0")])
        #expect(composer.draft.references == nil)
        composer.to = [maya]

        try await composer.send()
        await account.settle()

        let sentID = try #require(try await account.row(composer.id)?.serverEmailID)
        let sent = try #require(try await account.serverEmail(sentID))
        #expect(Set((sent.attachments ?? []).compactMap(\.blobId)) == ["e5-file0", "e5-logo"])
        #expect(sent.attachments?.first { $0.blobId == "e5-logo" }?.cid == "logo@northwind.example")
        #expect(account.server.downloadCount == 0)
        #expect(try await account.serverEmail("e5")?.has(.forwarded) == false)
        await account.advance(17)
        #expect(try await account.serverEmail("e5")?.has(.forwarded) == true)
    }

    @Test func forwardAsAttachmentAttachesTheWholeOriginal() async throws {
        await account.start()

        let composer = try await model.compose(.forward(emailID: "e5", asAttachment: true))

        #expect(composer.attachments.map(\.type) == ["message/rfc822"])
        #expect(composer.attachments.map(\.source) == [.server(blobId: "e5-blob")])
        #expect(composer.attachments.first?.name == "Invoice 2041 for September.eml")
        composer.from = EmailAddress(email: "fjord.k3x9@fastmail.com")
        #expect(composer.senderWarning == "The attached message shows the address it was delivered to.")
    }

    @Test func aShortenedOriginalIsFetchedAgainAndOfflineInlineForwardsAreBlocked() async throws {
        await account.start()
        let complete = try #require(try await account.client.emails(ids: ["e5"]).first)
        try await account.store.upsert([try truncated(complete)])

        let online = try await model.compose(.reply(emailID: "e5", all: false))
        #expect(online.quote?.isTruncated == false)
        #expect(online.notices.isEmpty)

        try await account.store.upsert([try truncated(complete)])
        account.server.isOffline = true
        let offline = try await model.compose(.reply(emailID: "e5", all: false))
        #expect(offline.quote?.isTruncated == true)
        #expect(offline.notices == [.quoteShortened])
        let forward = try await model.compose(.forward(emailID: "e5", asAttachment: false))
        #expect(forward.problems.contains(.inlineForwardIncomplete))

        // Never stored with its body: no quote, and an inline forward has nothing to forward.
        let reply = try await model.compose(.reply(emailID: "e3", all: false))
        #expect(reply.quote?.html == nil && reply.quote?.text == nil)
        #expect(reply.notices == [.originalUnavailableOffline])
        await #expect(throws: SendProblem.inlineForwardIncomplete) {
            try await model.compose(.forward(emailID: "e3", asAttachment: false))
        }
        let asAttachment = try await model.compose(.forward(emailID: "e3", asAttachment: true))
        #expect(asAttachment.attachments.map(\.source) == [.server(blobId: "e3-blob")])
    }

    /// The email as if its body had been cut short when it was fetched.
    private func truncated(_ email: Email) throws -> Email {
        let data = try JMAPCoding.makeEncoder().encode(email)
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(var values)? = object["bodyValues"]
        else { throw ComposeError.notFound }
        for (part, value) in values {
            guard case .object(var value) = value, case .string(let text)? = value["value"] else { continue }
            value["value"] = .string(String(text.prefix(40)))
            value["isTruncated"] = true
            values[part] = .object(value)
        }
        object["bodyValues"] = .object(values)
        return try JMAPCoding.makeDecoder().decode(Email.self, from: JSONEncoder().encode(JSONValue.object(object)))
    }

    // MARK: Attachments

    @Test func addedFilesAreKeptHereAndUploaded() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let file = FileManager.default.temporaryDirectory.appending(path: "ComposeTests-\(UUID().uuidString).txt")
        try Data("Packing list".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await composer.addAttachment(fileAt: file)
        await account.outbox.waitUntilIdle()

        let attachment = try #require(composer.attachments.first)
        #expect(attachment.type == "text/plain" && attachment.size == 12 && attachment.source == .local)
        #expect(composer.uploads == [attachment.id: .uploaded])
        let stored = try await account.store.outgoingAttachments(draftID: composer.id.uuidString)
        #expect(stored.map(\.blobID).allSatisfy { $0 != nil })
        #expect(account.server.uploadCount == 1)

        await composer.removeAttachment(attachment.id)
        #expect(composer.attachments.isEmpty)
        #expect(try await account.store.outgoingAttachments(draftID: composer.id.uuidString).isEmpty)
    }

    @Test func photosLoseTheirLocationBeforeTheyAreKept() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let photo = try Self.jpegWithLocation()
        #expect(Self.hasLocation(photo))

        try await composer.addAttachment(photo, name: "Lisbon.jpg", typeIdentifier: "public.jpeg")

        let attachment = try #require(composer.attachments.first)
        #expect(attachment.name == "Lisbon.jpg" && attachment.type == "image/jpeg")
        let kept = try await account.store.outgoingAttachmentData(id: attachment.id.uuidString)
        #expect(!Self.hasLocation(kept))
        #expect(attachment.size == kept.count)
    }

    @Test func aPhotoWhoseNameHidesWhatItIsGetsItsRealTypeAndExtension() async throws {
        await account.start()
        let composer = try await account.composeToMaya()
        let file = FileManager.default.temporaryDirectory.appending(path: "ComposeTests-\(UUID().uuidString).dat")
        try Self.jpegWithLocation().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await composer.addAttachment(fileAt: file)

        let attachment = try #require(composer.attachments.first)
        #expect(attachment.type == "image/jpeg")
        #expect(attachment.name == file.deletingPathExtension().lastPathComponent + ".jpeg")
        #expect(!Self.hasLocation(try await account.store.outgoingAttachmentData(id: attachment.id.uuidString)))
    }

    /// A small JPEG taken in Lisbon, as far as its metadata says.
    private static func jpegWithLocation() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let location: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 38.71, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 9.14, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: location] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyGPSDictionary] != nil
    }

    // MARK: Assembly

    @Test func cachedAssemblyIsTheAssemblersOwn() async throws {
        let quote = QuotedMessage(
            fromName: "Maya", fromEmail: "maya@lindqvist.example", to: [EmailAddress(email: "alex@fastmail.com")],
            date: OutboxTestAccount.start, subject: "Trip", html: "<p>Flights <b>booked</b></p><img src=\"cid:a@b\">",
            text: "Flights booked")
        let original = OriginalMessage(
            emailID: "e1", blobID: "e1-blob", quote: quote,
            inlineParts: [.init(cid: "a@b", blobId: "e1-img", type: "image/png")])
        let signature = Signature(html: "<div>Alex</div>", text: "-- \nAlex")
        let body = AttributedString("Thanks!\nSee you")
        let drafts = [
            MessageDraft(from: maya, body: body),
            MessageDraft(from: maya),
            MessageDraft(kind: .reply, from: maya, body: body, original: original),
            MessageDraft(kind: .reply, from: maya, original: original),
            MessageDraft(kind: .forward, from: maya, body: body, original: original),
            MessageDraft(kind: .new, from: maya, body: body, preservedTail: PreservedTail(html: "", text: "")),
            MessageDraft(kind: .new, from: maya, preservedTail: PreservedTail(html: "<blockquote>x</blockquote>", text: "> x")),
        ]
        let assembly = MessageAssembly()
        for draft in drafts {
            for signature in [nil, signature] {
                let hidden: Set<String> = ["alex@fastmail.com"]
                let expected = MessageAssembler.assemble(
                    draft, options: AssemblyOptions(signature: signature, hidesAddress: { hidden.contains($0) }))
                #expect(await assembly.body(for: draft, signature: signature, hiddenAddresses: hidden) == expected)
                // The cached skeleton again, with other text.
                var edited = draft
                edited.body = AttributedString("Edited")
                let editedExpected = MessageAssembler.assemble(
                    edited, options: AssemblyOptions(signature: signature, hidesAddress: { hidden.contains($0) }))
                #expect(await assembly.body(for: edited, signature: signature, hiddenAddresses: hidden) == editedExpected)
            }
        }
    }
}

private extension JSONValue {
    var objectKeys: [String]? {
        if case .object(let object) = self { object.keys.sorted() } else { nil }
    }
}
