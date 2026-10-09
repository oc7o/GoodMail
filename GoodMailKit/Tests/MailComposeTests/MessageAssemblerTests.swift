import Foundation
import JMAPKit
import Testing
@testable import MailCompose

struct MessageAssemblerTests {
    static let me = EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")
    /// ident-1 of the demo account.
    static let signature = Signature(html: "<div>Alex</div>", text: "-- \nAlex")

    static func quote(html: String? = nil, text: String? = "See you there.\n\n> earlier") -> QuotedMessage {
        QuotedMessage(
            fromName: "Maya Lindqvist", fromEmail: "maya@lindqvist.example",
            to: [EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"), EmailAddress(email: "shop@berg.example")],
            cc: [EmailAddress(name: "Jonas", email: "jonas@weber.example")], date: Fixture.date, subject: "Trip to Lisbon",
            html: html, text: text)
    }

    static func reply(body: String = "Sounds good!", quote: QuotedMessage = quote()) -> MessageDraft {
        MessageDraft(
            kind: .reply, from: me, to: [EmailAddress(email: "maya@lindqvist.example")], subject: "Re: Trip to Lisbon",
            body: AttributedString(body), original: OriginalMessage(emailID: "e3", blobID: "e3-blob", quote: quote))
    }

    @Test func replyLayout() {
        let body = MessageAssembler.assemble(Self.reply(), options: AssemblyOptions(signature: Self.signature))
        #expect(body.html == """
            <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>\
            <div>Sounds good!</div><div><br></div><div class="signature"><div>Alex</div></div><div><br></div>\
            <div>On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist &lt;maya@lindqvist.example&gt; wrote:</div>\
            <blockquote type="cite"><div>See you there.</div><div><br></div><div>&gt; earlier</div></blockquote>\
            </body></html>
            """)
        #expect(body.text == """
            Sounds good!

            -- \nAlex

            On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist <maya@lindqvist.example> wrote:
            > See you there.
            >
            >> earlier
            """)
        #expect(body.contentIDs.isEmpty)
    }

    @Test func forwardLayoutHidesTheUsersOtherAddresses() {
        let html = "<p>Hello <img src=\"cid:logo@northwind.example\"> <img src=\"https://t.example/p.gif\" width=1 height=1></p>"
        var draft = Self.reply(body: "FYI", quote: Self.quote(html: html, text: nil))
        draft.kind = .forward
        draft.from = EmailAddress(email: "fjord.k3x9@fastmail.com")
        let options = AssemblyOptions(hidesAddress: { ["alex@fastmail.com", "shop@berg.example"].contains($0) })
        let body = MessageAssembler.assemble(draft, options: options)
        #expect(body.html == """
            <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>\
            <div>FYI</div><div><br></div><div>Begin forwarded message:</div><blockquote type="cite">\
            <div><b>From:</b> Maya Lindqvist &lt;maya@lindqvist.example&gt;</div>\
            <div><b>Subject:</b> Trip to Lisbon</div><div><b>Date:</b> 9 Oct 2026 at 14:03 UTC</div>\
            <div><b>Cc:</b> Jonas &lt;jonas@weber.example&gt;</div><div><br></div>\
            <p>Hello <img src="cid:logo@northwind.example"> </p></blockquote></body></html>
            """)
        #expect(body.text == """
            FYI

            Begin forwarded message:

            From: Maya Lindqvist <maya@lindqvist.example>
            Subject: Trip to Lisbon
            Date: 9 Oct 2026 at 14:03 UTC
            Cc: Jonas <jonas@weber.example>

            Hello
            """)
        #expect(!body.html.contains("alex@fastmail.com") && !body.text.contains("alex@fastmail.com"))
        #expect(!body.html.contains("shop@berg.example") && !body.text.contains("shop@berg.example"))
        #expect(body.contentIDs == ["logo@northwind.example"])
        #expect(body.removedTrackers == 1)
    }

    @Test func forwardAsAttachmentHasNoQuote() {
        var draft = Self.reply(body: "")
        draft.kind = .forwardAsAttachment
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions())
        #expect(body.html == "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body></body></html>")
        #expect(body.text.isEmpty)
    }

    /// C19: the attribution is UTC in English, whatever the device's time zone.
    @Test func attributionIsUTCWhateverTheTimeZone() {
        let quote = Self.quote()
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!
        let attribution = MessageAssembler.attribution(for: quote)
        NSTimeZone.default = saved
        #expect(attribution == "On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist <maya@lindqvist.example> wrote:")

        var late = quote
        late.date = Fixture.date.addingTimeInterval(9 * 3600 + 56 * 60) // 23:59 UTC is already the next day in Europe
        late.fromName = nil
        #expect(MessageAssembler.attribution(for: late) == "On 9 Oct 2026 at 23:59 UTC, maya@lindqvist.example wrote:")
    }

    @Test func hiddenSenderBecomesI() {
        var draft = Self.reply()
        draft.original?.quote.fromEmail = "alex@fastmail.com"
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions(hidesAddress: { $0 == "alex@fastmail.com" }))
        #expect(body.text.contains("On 9 Oct 2026 at 14:03 UTC, I wrote:"))
        #expect(!body.html.contains("alex@fastmail.com"))
    }

    /// C18: one delimiter whether or not the identity's text signature has one.
    @Test(arguments: [("-- \nAlex", "-- \nAlex"), ("Alex", "-- \nAlex"), ("--\nAlex", "--\nAlex"), ("Alex\r\nBerg", "-- \nAlex\nBerg")])
    func textSignatureGetsExactlyOneDelimiter(signature: String, expected: String) {
        let draft = MessageDraft(from: Self.me, body: AttributedString("Hi"))
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions(signature: Signature(html: nil, text: signature)))
        #expect(body.text == "Hi\n\n" + expected)
        #expect(body.text.components(separatedBy: "-- \n").count <= 2)
    }

    @Test func htmlOnlySignatureProvidesTheText() {
        let draft = MessageDraft(from: Self.me, body: AttributedString("Hi"))
        let signature = Signature(html: "<div><b>Alex</b> · <a href=\"https://berg.example\">berg.example</a></div><img src=\"cid:sig@x\">", text: nil)
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions(signature: signature))
        #expect(body.text == "Hi\n\n-- \nAlex · berg.example <https://berg.example>")
        #expect(body.contentIDs == ["sig@x"])
    }

    @Test func noSignatureWhenTheDraftOrSendDoesNotWantOne() {
        var draft = MessageDraft(from: Self.me, body: AttributedString("Hi"))
        #expect(!MessageAssembler.assemble(draft, options: AssemblyOptions()).html.contains("signature"))
        draft.includesSignature = false
        #expect(!MessageAssembler.assemble(draft, options: AssemblyOptions(signature: Self.signature)).html.contains("signature"))
        #expect(!MessageAssembler.assemble(draft, options: AssemblyOptions(signature: Signature(html: " ", text: "")))
            .html.contains("signature"))
    }

    /// C34: nothing marks the message as GoodMail's.
    @Test func noDataAttributesOrMarkers() {
        let html = "<div data-goodmail=\"x\" data-id=\"1\" class=\"gm-quote\" id=\"q\"><p data-x=\"y\">quoted</p></div>"
        let draft = Self.reply(quote: Self.quote(html: html, text: nil))
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions(signature: Self.signature))
        #expect(body.html.range(of: #"\sdata-"#, options: .regularExpression) == nil)
        #expect(!body.html.lowercased().contains("goodmail"))
        #expect(!body.html.contains("id=") && !body.html.contains("gm-"))
        #expect(!body.html.contains("<title") && !body.html.contains("generator"))
    }

    @Test func quotedLinksAndTrackersAreCleaned() {
        let html = "<a href=\"https://shop.example/x?utm_source=news&amp;id=4\">deal</a><img src=\"https://mailtrack.io/p.gif\">"
        let body = MessageAssembler.assemble(Self.reply(quote: Self.quote(html: html, text: nil)), options: AssemblyOptions())
        #expect(body.html.contains("<a href=\"https://shop.example/x?id=4\">deal</a>"))
        #expect(!body.html.contains("mailtrack"))
        #expect(body.removedTrackers == 1)
        #expect(body.text.hasSuffix("> deal <https://shop.example/x?id=4>"))
    }

    @Test func preservedTailIsSentAsItIs() {
        let tail = PreservedTail(
            html: "<div>On Thu, 9 Oct 2026, at 16:03, Maya wrote:</div><blockquote type=\"cite\"><div>Hi <img src=\"cid:c1@x\"></div></blockquote>",
            text: "On Thu, 9 Oct 2026, at 16:03, Maya wrote:\n> Hi")
        var draft = Self.reply()
        draft.preservedTail = tail
        let body = MessageAssembler.assemble(draft, options: AssemblyOptions())
        #expect(body.html == """
            <!DOCTYPE html><html><head><meta charset="utf-8"></head><body><div>Sounds good!</div><div><br></div>\
            \(tail.html)</body></html>
            """)
        #expect(body.text == "Sounds good!\n\n" + tail.text)
        #expect(body.contentIDs == ["c1@x"])
    }

    @Test func plainTextOriginalsKeepTheirSpacing() {
        let html = MessageAssembler.html(fromPlainText: "a  b\n\n\tc <d>\r\n")
        #expect(html == "<div>a &nbsp;b</div><div><br></div><div><span style=\"white-space: pre\">\t</span>c &lt;d&gt;</div><div><br></div>")
    }
}
