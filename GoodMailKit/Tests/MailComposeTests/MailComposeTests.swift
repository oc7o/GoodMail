import Foundation
import JMAPKit
import SwiftUI
import Testing
@testable import MailCompose

/// Helpers shared by the MailCompose suites.
enum Fixture {
    static let context = MailFontStyle.context

    static func selection(of substring: String, in text: AttributedString) -> AttributedTextSelection {
        AttributedTextSelection(range: text.range(of: substring)!)
    }

    static func caret(at offset: Int, in text: AttributedString) -> AttributedTextSelection {
        AttributedTextSelection(insertionPoint: text.characters.index(text.startIndex, offsetBy: offset))
    }

    /// The body of the editor spike's writer experiment (E15), formatted through the editing commands.
    static func formattedBody() -> AttributedString {
        var text = AttributedString(
            "Hello Anna,\n\nthanks for the notes. Three things:\nfirst point\nsecond point\n\n"
                + "See https://example.com/doc for details.  Two  spaces.\nCheers")
        var selection = selection(of: "thanks", in: text)
        text.updateFont({ $0.isBold = true }, selection: &selection, in: context)
        selection = Self.selection(of: "notes", in: text)
        text.updateFont({ $0.isItalic = true }, selection: &selection, in: context)
        text.setUnderline(true, selection: &selection)
        selection = Self.selection(of: "Three things", in: text)
        text.setColor(MailPalette.colors[0], selection: &selection)
        selection = Self.selection(of: "first point\nsecond point", in: text)
        text.toggleList(numbered: false, selection: &selection)
        selection = Self.selection(of: "https://example.com/doc", in: text)
        text.setLink(URL(string: "https://example.com/doc?utm_source=x&page=2"), selection: &selection)
        selection = Self.selection(of: "details", in: text)
        text.updateFont({ $0.size = .large }, selection: &selection, in: context)
        text.setStrikethrough(true, selection: &selection)
        selection = Self.selection(of: "Cheers", in: text)
        text.updateFont({ $0.isMonospaced = true }, selection: &selection, in: context)
        return text
    }

    typealias Address = (name: String?, email: String)

    /// An email as JMAP returns it with `Email.Properties.full` and body values.
    static func email(
        id: String = "e1", blobId: String? = "e1-blob", from: [Address] = [("Maya Lindqvist", "maya@lindqvist.example")],
        to: [Address] = [("Alex Berg", "alex@fastmail.com")], cc: [Address] = [], bcc: [Address] = [],
        replyTo: [Address]? = nil, subject: String? = "Trip to Lisbon", sentAt: String = "2026-10-09T14:03:00Z",
        messageId: [String]? = ["m1@lindqvist.example"], inReplyTo: [String]? = nil, references: [String]? = nil,
        html: String? = nil, text: String? = "Hello Alex", truncated: Bool = false, keywords: [String] = ["$seen"],
        attachments: [[String: Any]] = []
    ) -> Email {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        func addresses(_ list: [Address]) -> Any {
            list.map { ["name": orNull($0.name), "email": $0.email] as [String: Any] }
        }
        var bodyValues: [String: Any] = [:]
        var htmlBody: [[String: Any]] = []
        var textBody: [[String: Any]] = []
        if let text {
            bodyValues["t"] = ["value": text, "isEncodingProblem": false, "isTruncated": truncated]
            textBody = [["partId": "t", "type": "text/plain"]]
        }
        if let html {
            bodyValues["h"] = ["value": html, "isEncodingProblem": false, "isTruncated": truncated]
            htmlBody = [["partId": "h", "type": "text/html"]]
            if text == nil { textBody = htmlBody }
        } else {
            htmlBody = textBody
        }
        let json: [String: Any] = [
            "id": id, "blobId": orNull(blobId), "threadId": "t1", "mailboxIds": ["inbox": true],
            "keywords": Dictionary(uniqueKeysWithValues: keywords.map { ($0, true) }), "size": 4242,
            "receivedAt": sentAt, "sentAt": sentAt, "from": addresses(from), "to": addresses(to),
            "cc": addresses(cc), "bcc": addresses(bcc), "replyTo": orNull(replyTo.map(addresses)),
            "subject": orNull(subject), "messageId": orNull(messageId),
            "inReplyTo": orNull(inReplyTo), "references": orNull(references),
            "hasAttachment": !attachments.isEmpty, "preview": "",
            "bodyValues": bodyValues, "htmlBody": htmlBody, "textBody": textBody, "attachments": attachments,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JMAPCoding.makeDecoder().decode(Email.self, from: data)
    }

    static func attachment(
        _ name: String, type: String, blobId: String, size: Int = 1000, inline cid: String? = nil
    ) -> [String: Any] {
        [
            "partId": NSNull(), "blobId": blobId, "name": name, "type": type, "size": size,
            "disposition": cid == nil ? "attachment" : "inline", "cid": cid.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// 2026-10-09 14:03:00 UTC.
    static let date = Date(timeIntervalSince1970: 1_791_554_580)
}
