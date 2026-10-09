import Foundation
import JMAPKit
import Testing
@testable import MailCompose

struct ReplyBuilderTests {
    static let me = EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")
    /// The user's addresses: the login, the wildcard identity *@berg.example and a masked address.
    static let isOwn: @Sendable (String) -> Bool = { address in
        let address = address.lowercased()
        return address == "alex@fastmail.com" || address.hasSuffix("@berg.example") || address == "fjord.k3x9@fastmail.com"
    }

    @Test(arguments: [
        ("Lisbon", "Re: Lisbon"), ("Re: Lisbon", "Re: Lisbon"), ("RE: Lisbon", "RE: Lisbon"), ("AW: Reise", "AW: Reise"),
        ("Sv: Resa", "Sv: Resa"), ("Antw: Reis", "Antw: Reis"), ("  Fwd: deal ", "Re: Fwd: deal"), ("", "Re:"),
        ("Reunion", "Re: Reunion"),
    ])
    func replySubjects(subject: String, expected: String) {
        #expect(ReplyBuilder.replySubject(subject) == expected)
    }

    @Test func forwardSubjects() {
        #expect(ReplyBuilder.forwardSubject("Invoice") == "Fwd: Invoice")
        #expect(ReplyBuilder.forwardSubject("Fwd: Invoice") == "Fwd: Invoice")
        #expect(ReplyBuilder.forwardSubject("FW: Invoice") == "FW: Invoice")
        #expect(ReplyBuilder.forwardSubject("Re: Invoice") == "Fwd: Re: Invoice")
        #expect(ReplyBuilder.forwardSubject(nil) == "Fwd:")
        #expect(ReplyBuilder.replySubject(nil) == "Re:")
    }

    @Test func referencesContinueTheChain() {
        let withReferences = Fixture.email(
            messageId: ["m3@x.example"], inReplyTo: ["m2@x.example"], references: ["m1@x.example", "m2@x.example"])
        let reply = ReplyBuilder.reply(to: withReferences, all: false, from: Self.me, isOwn: Self.isOwn)
        #expect(reply.inReplyTo == ["m3@x.example"])
        #expect(reply.references == ["m1@x.example", "m2@x.example", "m3@x.example"])

        let onlyInReplyTo = Fixture.email(messageId: ["m3@x.example"], inReplyTo: ["m2@x.example"])
        #expect(ReplyBuilder.reply(to: onlyInReplyTo, all: false, from: Self.me, isOwn: Self.isOwn).references
                == ["m2@x.example", "m3@x.example"])

        let first = Fixture.email(messageId: ["m1@x.example"])
        #expect(ReplyBuilder.reply(to: first, all: false, from: Self.me, isOwn: Self.isOwn).references == ["m1@x.example"])

        let noID = Fixture.email(messageId: nil)
        let orphan = ReplyBuilder.reply(to: noID, all: false, from: Self.me, isOwn: Self.isOwn)
        #expect(orphan.inReplyTo == nil && orphan.references == nil)
    }

    @Test func replyGoesToReplyToElseFrom() {
        let plain = ReplyBuilder.reply(to: Fixture.email(), all: false, from: Self.me, isOwn: Self.isOwn)
        #expect(plain.to == [EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")])
        #expect(plain.cc.isEmpty)
        #expect(plain.kind == .reply)
        #expect(plain.from == Self.me)
        #expect(plain.messageID.hasSuffix("@fastmail.com"))
        #expect(plain.subject == "Re: Trip to Lisbon")

        let list = Fixture.email(replyTo: [(nil, "list@lists.example")])
        #expect(ReplyBuilder.reply(to: list, all: false, from: Self.me, isOwn: Self.isOwn).to
                == [EmailAddress(email: "list@lists.example")])
    }

    /// C30: reply-all leaves out every address of the user, including one that only a wildcard identity matches.
    @Test func replyAllLeavesOutEveryOwnAddress() {
        let original = Fixture.email(
            to: [("Alex Berg", "alex@fastmail.com"), (nil, "shop@berg.example"), ("Jonas Weber", "jonas@weber.example")],
            cc: [("Priya", "Priya@Raman.example"), ("Maya", "MAYA@lindqvist.example"), (nil, "priya@raman.example"),
                 (nil, "fjord.k3x9@fastmail.com")])
        let reply = ReplyBuilder.reply(
            to: original, all: true, from: EmailAddress(email: "shop@berg.example"), isOwn: Self.isOwn)
        #expect(reply.kind == .replyAll)
        #expect(reply.to == [EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")])
        #expect(reply.cc == [
            EmailAddress(name: "Jonas Weber", email: "jonas@weber.example"),
            EmailAddress(name: "Priya", email: "Priya@Raman.example"),
        ])
        #expect(reply.messageID.hasSuffix("@berg.example"))
    }

    /// C6: a follow-up to a message the user sent goes to that message's recipients.
    @Test func replyingToYourOwnMessageGoesToItsRecipients() {
        let sent = Fixture.email(
            from: [(nil, "fjord.k3x9@fastmail.com")], to: [("Fjord Support", "support@fjord-outdoor.example")],
            cc: [(nil, "orders@fjord-outdoor.example"), (nil, "alex@fastmail.com")])
        let reply = ReplyBuilder.reply(
            to: sent, all: false, from: EmailAddress(email: "fjord.k3x9@fastmail.com"), isOwn: Self.isOwn)
        #expect(reply.to == [EmailAddress(name: "Fjord Support", email: "support@fjord-outdoor.example")])
        #expect(reply.cc.isEmpty)

        let all = ReplyBuilder.reply(to: sent, all: true, from: EmailAddress(email: "fjord.k3x9@fastmail.com"), isOwn: Self.isOwn)
        #expect(all.to == [EmailAddress(name: "Fjord Support", email: "support@fjord-outdoor.example")])
        #expect(all.cc == [EmailAddress(email: "orders@fjord-outdoor.example")])
    }

    @Test func replyKeepsAQuoteSnapshot() throws {
        let original = Fixture.email(
            html: "<p>Hi <img src=\"cid:logo@x\"></p>", text: "Hi", truncated: true,
            attachments: [Fixture.attachment("logo.png", type: "image/png", blobId: "b-logo", inline: "logo@x")])
        let reply = ReplyBuilder.reply(to: original, all: false, from: Self.me, isOwn: Self.isOwn)
        let source = try #require(reply.original)
        #expect(source.emailID == "e1")
        #expect(source.blobID == "e1-blob")
        #expect(source.quote.html == "<p>Hi <img src=\"cid:logo@x\"></p>")
        #expect(source.quote.text == "Hi")
        #expect(source.quote.isTruncated)
        #expect(source.quote.date == Fixture.date)
        #expect(source.quote.fromName == "Maya Lindqvist")
        #expect(source.inlineParts == [.init(cid: "logo@x", blobId: "b-logo", type: "image/png", name: "logo.png")])
        #expect(reply.attachments.isEmpty)
    }

    @Test func forwardKeepsAttachmentsByBlobID() throws {
        let invoice = Fixture.email(
            id: "e5", blobId: "e5-blob", from: [("Northwind Hosting", "billing@northwind.example")],
            subject: "Invoice 2041 for September", messageId: ["e5@demo"], references: ["x@demo"],
            html: "<img src=\"cid:logo@northwind.example\"><p>Hello</p>", text: nil,
            attachments: [
                Fixture.attachment("Invoice-2041.pdf", type: "application/pdf", blobId: "e5-file0", size: 61_440),
                Fixture.attachment("logo.svg", type: "image/svg+xml", blobId: "e5-logo", size: 420, inline: "logo@northwind.example"),
            ])
        let forward = ReplyBuilder.forward(invoice, asAttachment: false, from: Self.me)
        #expect(forward.kind == .forward)
        #expect(forward.subject == "Fwd: Invoice 2041 for September")
        #expect(forward.to.isEmpty && forward.inReplyTo == nil && forward.references == nil)
        #expect(forward.attachments.map(\.source) == [.server(blobId: "e5-file0")])
        #expect(forward.attachments.first?.name == "Invoice-2041.pdf")
        #expect(forward.attachments.first?.size == 61_440)
        #expect(forward.original?.inlineParts.map(\.blobId) == ["e5-logo"])

        let asAttachment = ReplyBuilder.forward(invoice, asAttachment: true, from: Self.me)
        #expect(asAttachment.kind == .forwardAsAttachment)
        let message = try #require(asAttachment.attachments.first)
        #expect(asAttachment.attachments.count == 1)
        #expect(message.name == "Invoice 2041 for September.eml")
        #expect(message.type == "message/rfc822")
        #expect(message.source == .server(blobId: "e5-blob"))
        #expect(asAttachment.original?.emailID == "e5")
    }

    @Test func messageFileNamesAreSafe() {
        #expect(ReplyBuilder.messageFileName(subject: "Q3/Q4: plans") == "Q3-Q4- plans.eml")
        #expect(ReplyBuilder.messageFileName(subject: "  ") == "Forwarded Message.eml")
    }
}
