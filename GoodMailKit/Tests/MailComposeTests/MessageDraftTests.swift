import Foundation
import JMAPKit
import SwiftUI
import Testing
@testable import MailCompose

struct MessageDraftTests {
    static func sample() -> MessageDraft {
        var body = Fixture.formattedBody()
        body[body.range(of: "Hello Anna,")!].alignment = .center
        body[body.range(of: "Hello Anna,")!].writingDirection = .rightToLeft
        let quote = QuotedMessage(
            fromName: "Maya Lindqvist", fromEmail: "maya@lindqvist.example",
            to: [EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")], cc: [], date: Fixture.date,
            subject: "Trip", html: "<p>Hi</p>", text: "Hi", isTruncated: true)
        return MessageDraft(
            kind: .replyAll, from: EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"),
            to: [EmailAddress(name: "Maya", email: "maya@lindqvist.example")], cc: [EmailAddress(email: "jonas@weber.example")],
            bcc: [EmailAddress(email: "me@berg.example")], replyTo: [EmailAddress(email: "alex@berg.example")],
            subject: "Re: Trip", body: body,
            attachments: [
                DraftAttachment(name: "Scan.pdf", type: "application/pdf", size: 1234, source: .local),
                DraftAttachment(name: "Ticket.pdf", type: "application/pdf", size: 99, source: .server(blobId: "G123")),
            ],
            inReplyTo: ["m1@x"], references: ["m0@x", "m1@x"],
            original: OriginalMessage(
                emailID: "e3", blobID: "e3-blob", quote: quote,
                inlineParts: [.init(cid: "logo@x", blobId: "b1", type: "image/png", name: "logo.png")]),
            preservedTail: PreservedTail(
                html: "<div>On …, X wrote:</div><blockquote type=\"cite\">y</blockquote>", text: "On …, X wrote:\n> y",
                inlineParts: [.init(cid: "c@x", blobId: "b2", type: "image/gif")]),
            includesSignature: false)
    }

    /// The body keeps its attributes through the JSON the store keeps, as the editor spike verified (E22).
    @Test func roundTripsThroughJSON() throws {
        let draft = Self.sample()
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(MessageDraft.self, from: data)
        #expect(decoded == draft)
        #expect(decoded.body == draft.body)
        #expect(MailHTMLWriter.write(decoded.body) == MailHTMLWriter.write(draft.body))
    }

    @Test func olderDraftsDecodeWithDefaults() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","messageID":"abc@fastmail.com","tail":{"html":"x"}}"#
        let decoded = try JSONDecoder().decode(MessageDraft.self, from: Data(json.utf8))
        #expect(decoded.id == id)
        #expect(decoded.messageID == "abc@fastmail.com")
        #expect(decoded.kind == .new && decoded.to.isEmpty && decoded.subject.isEmpty && decoded.body.characters.isEmpty)
        #expect(decoded.includesSignature)

        let tail = try JSONDecoder().decode(PreservedTail.self, from: Data(#"{"html":"<b>x</b>","text":"x"}"#.utf8))
        #expect(tail == PreservedTail(html: "<b>x</b>", text: "x"))
    }

    @Test func messageIDsFollowTheSendersDomain() {
        let draft = MessageDraft(from: EmailAddress(email: "Fjord.K3X9@FastMail.com"))
        #expect(draft.messageID.hasSuffix("@fastmail.com"))
        #expect(draft.messageIDDomain == "fastmail.com")
        #expect(UUID(uuidString: String(draft.messageID.prefix(36))) != nil)
        #expect(!draft.messageID.contains("<") && !draft.messageID.contains(">"))
        #expect(MessageDraft.newMessageID(domain: "berg.example") != MessageDraft.newMessageID(domain: "berg.example"))
        #expect(MessageDraft(from: nil).messageID.hasSuffix("@invalid"))
    }

    @Test func signatureEmptiness() {
        #expect(Signature(html: nil, text: nil).isEmpty)
        #expect(Signature(html: " \n", text: "").isEmpty)
        #expect(!Signature(html: nil, text: "-- \nAlex").isEmpty)
    }
}

struct AddressParserTests {
    @Test func parsesLists() {
        let parsed = AddressParser.parse(
            #"Maya Lindqvist <maya@lindqvist.example>, b@y.example; "Berg, Alex" <alex@berg.example>,"#
                + "\n<jonas@weber.example>, mailto:priya@raman.example")
        #expect(parsed.addresses == [
            EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example"),
            EmailAddress(email: "b@y.example"),
            EmailAddress(name: "Berg, Alex", email: "alex@berg.example"),
            EmailAddress(email: "jonas@weber.example"),
            EmailAddress(email: "priya@raman.example"),
        ])
        #expect(parsed.remainder.isEmpty)
    }

    @Test func quotedNamesKeepTheirPunctuation() {
        let parsed = AddressParser.parse(#""Alex \"AB\" Berg; Jr." <alex@berg.example>"#)
        #expect(parsed.addresses == [EmailAddress(name: "Alex \"AB\" Berg; Jr.", email: "alex@berg.example")])
        #expect(AddressParser.parse("Maya Lindqvist maya@lindqvist.example").addresses
                == [EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")])
    }

    @Test func invalidInput() {
        let parsed = AddressParser.parse("foo, bar@x.example, maya@lin")
        #expect(parsed.addresses == [EmailAddress(email: "foo"), EmailAddress(email: "bar@x.example")])
        #expect(parsed.remainder == "maya@lin")
        #expect(!AddressParser.isValid(parsed.addresses[0].email))

        #expect(AddressParser.parse("  ").addresses.isEmpty)
        #expect(AddressParser.parse(",,;").addresses.isEmpty)
        #expect(AddressParser.parse("Maya <").remainder == "Maya <")
    }

    @Test(arguments: [
        ("maya@lindqvist.example", true), ("a.b+tag@sub.example.co.uk", true), ("o'brien@example.ie", true),
        ("josé@exämple.de", true), ("x@xn--bcher-kva.example", true),
        ("", false), ("plain", false), ("@example.com", false), ("a@", false), ("a@localhost", false),
        ("a@@example.com", false), ("a b@example.com", false), (".a@example.com", false), ("a..b@example.com", false),
        ("a@example..com", false), ("a@-example.com", false), ("a@example.123", false), ("a@[192.168.1.1]", false),
        ("\"quoted\"@example.com", false), (String(repeating: "a", count: 65) + "@example.com", false),
    ])
    func validatesAddresses(address: String, valid: Bool) {
        #expect(AddressParser.isValid(address) == valid)
    }

    @Test func domains() {
        #expect(AddressParser.domain(of: "Alex@Berg.Example") == "berg.example")
        #expect(AddressParser.domain(of: "*@berg.example") == "berg.example")
        #expect(AddressParser.domain(of: "nodomain") == nil)
        #expect(AddressParser.domain(of: "a@") == nil)
    }

    @Test func suggestionsAreIdentifiedByAddress() {
        let suggestion = AddressSuggestion(address: EmailAddress(name: "Maya", email: "Maya@Lindqvist.example"), source: .both)
        #expect(suggestion.id == "maya@lindqvist.example")
    }
}
