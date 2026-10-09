import Foundation
import JMAPKit
import Testing
@testable import MailCompose

struct DraftParserTests {
    static let me = EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")
    static let signature = Signature(html: "<div>Alex</div>", text: "-- \nAlex")

    /// A draft as GoodMail saves it: assembled, then stored by the server.
    static func saved(_ draft: MessageDraft, signature: Signature?, attachments: [[String: Any]] = [], truncated: Bool = false)
        -> (email: Email, body: OutgoingBody)
    {
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions(signature: signature))
        let email = Fixture.email(
            id: "d1", from: draft.from.map { [($0.name, $0.email)] } ?? [],
            to: draft.to.map { ($0.name, $0.email) }, cc: draft.cc.map { ($0.name, $0.email) }, subject: draft.subject,
            messageId: [draft.messageID], inReplyTo: draft.inReplyTo, references: draft.references, html: body.html,
            text: body.text, truncated: truncated, keywords: ["$draft", "$seen"], attachments: attachments)
        return (email, body)
    }

    static func reply() -> MessageDraft {
        let quote = QuotedMessage(
            fromName: "Maya Lindqvist", fromEmail: "maya@lindqvist.example", date: Fixture.date, subject: "Trip",
            html: "<div>Booked! <img src=\"cid:map@lindqvist.example\"></div><div><a href=\"https://x.example/?utm_source=a\">link</a></div>",
            text: "Booked!\nlink")
        return MessageDraft(
            kind: .reply, from: me, to: [EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")],
            subject: "Re: Trip", body: Fixture.formattedBody(), inReplyTo: ["m1@lindqvist.example"],
            references: ["m1@lindqvist.example"], original: OriginalMessage(emailID: "e3", blobID: "e3-blob", quote: quote))
    }

    @Test func goodMailDraftsComeBackExactly() throws {
        let draft = Self.reply()
        let attachments = [
            Fixture.attachment("Ticket.pdf", type: "application/pdf", blobId: "G1", size: 2048),
            Fixture.attachment("map.png", type: "image/png", blobId: "G2", inline: "map@lindqvist.example"),
        ]
        let (email, body) = Self.saved(draft, signature: Self.signature, attachments: attachments)
        let parsed = DraftParser.parse(email, fallbackDomain: "fastmail.com")

        #expect(parsed.fidelity == .exact)
        #expect(parsed.draft.includesSignature)
        #expect(parsed.draft.kind == .reply)
        #expect(parsed.draft.messageID == draft.messageID)
        #expect(parsed.draft.from == Self.me)
        #expect(parsed.draft.to == draft.to)
        #expect(parsed.draft.subject == "Re: Trip")
        #expect(parsed.draft.inReplyTo == ["m1@lindqvist.example"])
        #expect(MailHTMLWriter.write(parsed.draft.body) == MailHTMLWriter.write(draft.body))
        #expect(!String(parsed.draft.body.characters).contains("Alex\n"))
        #expect(parsed.draft.attachments.map(\.source) == [.server(blobId: "G1")])
        #expect(parsed.draft.attachments.first?.name == "Ticket.pdf")

        let tail = try #require(parsed.draft.preservedTail)
        #expect(tail.html.hasPrefix("<div>On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist &lt;maya@lindqvist.example&gt; wrote:</div>"))
        #expect(tail.html.hasSuffix("</blockquote>"))
        #expect(tail.text.hasPrefix("On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist <maya@lindqvist.example> wrote:\n> Booked!"))
        #expect(tail.inlineParts == [.init(cid: "map@lindqvist.example", blobId: "G2", type: "image/png", name: "map.png")])

        let again = MessageAssembler.assemble(parsed.draft, options: AssemblyOptions(signature: Self.signature))
        #expect(again.html == body.html)
        #expect(again.text == body.text)
    }

    @Test func draftsWithoutSignatureOrQuote() {
        var draft = MessageDraft(from: EmailAddress(email: "fjord.k3x9@fastmail.com"), subject: "Question", body: AttributedString("Hi\n\nthere\n"))
        let (email, body) = Self.saved(draft, signature: nil)
        let parsed = DraftParser.parse(email, fallbackDomain: "fastmail.com")
        #expect(parsed.fidelity == .exact)
        #expect(!parsed.draft.includesSignature)
        #expect(parsed.draft.preservedTail == nil)
        #expect(String(parsed.draft.body.characters) == "Hi\n\nthere\n")
        #expect(MessageAssembler.assemble(parsed.draft, options: AssemblyOptions()).html == body.html)

        draft.body = AttributedString()
        let empty = DraftParser.parse(Self.saved(draft, signature: Self.signature).email, fallbackDomain: "fastmail.com")
        #expect(empty.draft.body.characters.isEmpty)
        #expect(empty.draft.includesSignature)
    }

    @Test func forwardsKeepTheForwardedMessage() throws {
        var draft = Self.reply()
        draft.kind = .forward
        draft.subject = "Fwd: Trip"
        draft.inReplyTo = nil
        draft.references = nil
        let (email, body) = Self.saved(draft, signature: Self.signature)
        let parsed = DraftParser.parse(email, fallbackDomain: "fastmail.com")
        #expect(parsed.fidelity == .exact)
        #expect(parsed.draft.kind == .forward)
        let tail = try #require(parsed.draft.preservedTail)
        #expect(tail.text.hasPrefix("Begin forwarded message:\n\nFrom: Maya Lindqvist <maya@lindqvist.example>"))
        #expect(MessageAssembler.assemble(parsed.draft, options: AssemblyOptions(signature: Self.signature)).html == body.html)
    }

    /// A draft written in Fastmail's web client, with an image in the text and a quoted original.
    @Test func foreignDraftWithAnInlineImageIsSimplified() throws {
        let html = """
            <!DOCTYPE html><html><head><title></title><style type="text/css">p.MsoNormal{margin:0}</style></head>\
            <body><div>Thanks, see the chart:<br></div><div><img src="cid:chart@fm" alt="chart"><br></div>\
            <div><br></div><div>On Thu, 9 Oct 2026, at 16:03, Maya Lindqvist wrote:<br></div>\
            <blockquote type="cite" id="qt" style=""><div>Can you send the numbers? \
            <a href="https://numbers.example/q?utm_source=mail&amp;q=3">numbers</a><br></div></blockquote>\
            <div><br></div></body></html>
            """
        let email = Fixture.email(
            id: "d2", from: [("Alex Berg", "alex@fastmail.com")], subject: "Re: Numbers", messageId: ["web-1@fastmail.com"],
            inReplyTo: ["m9@lindqvist.example"], html: html, text: nil, keywords: ["$draft"],
            attachments: [Fixture.attachment("chart.png", type: "image/png", blobId: "G9", inline: "chart@fm")])
        let parsed = DraftParser.parse(email, fallbackDomain: "fastmail.com")

        #expect(parsed.fidelity == .simplified([.images]))
        #expect(!parsed.draft.includesSignature)
        #expect(parsed.draft.kind == .reply)
        #expect(parsed.draft.messageID == "web-1@fastmail.com")
        #expect(String(parsed.draft.body.characters) == "Thanks, see the chart:\n")
        #expect(parsed.draft.attachments.isEmpty)
        let tail = try #require(parsed.draft.preservedTail)
        #expect(tail.html == """
            <div>On Thu, 9 Oct 2026, at 16:03, Maya Lindqvist wrote:<br></div><blockquote type="cite">\
            <div>Can you send the numbers? <a href="https://numbers.example/q?q=3">numbers</a><br></div></blockquote>
            """)
        #expect(tail.text == "On Thu, 9 Oct 2026, at 16:03, Maya Lindqvist wrote:\n> Can you send the numbers? numbers <https://numbers.example/q?q=3>")
        #expect(tail.inlineParts.isEmpty)
    }

    @Test func plainTextDraftsAreExact() {
        let email = Fixture.email(
            id: "d3", subject: "Note", messageId: nil, html: nil, text: "Hello,\r\nthis is plain.\n\n-- \nMax", keywords: ["$draft"])
        let parsed = DraftParser.parse(email, fallbackDomain: "fastmail.com")
        #expect(parsed.fidelity == .exact)
        #expect(String(parsed.draft.body.characters) == "Hello,\nthis is plain.\n\n-- \nMax")
        #expect(!parsed.draft.includesSignature)
        #expect(parsed.draft.messageID.hasSuffix("@lindqvist.example"))
        #expect(parsed.draft.kind == .new)
    }

    @Test func truncatedDraftsAreNotEditedBlindly() {
        let (email, _) = Self.saved(MessageDraft(from: Self.me, body: AttributedString("long")), signature: nil, truncated: true)
        #expect(DraftParser.parse(email, fallbackDomain: "fastmail.com").fidelity == .simplified([.other]))
    }

    @Test func missingSenderFallsBackToTheAccountDomain() {
        let email = Fixture.email(from: [], messageId: nil, html: nil, text: "x")
        #expect(DraftParser.parse(email, fallbackDomain: "fastmail.com").draft.messageID.hasSuffix("@fastmail.com"))
    }
}
