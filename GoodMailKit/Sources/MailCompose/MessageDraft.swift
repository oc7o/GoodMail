import Foundation
import JMAPKit
import SwiftUI

/// One composition: everything needed to save it as a draft and to send it, independent of any view.
public struct MessageDraft: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case new, reply, replyAll, forward, forwardAsAttachment
    }

    public var id: UUID
    /// "<uuid>@<domain of From>" without angle brackets. Every saved version and the sent message share it, and
    /// it changes with the From domain, so a masked address never sends another domain's id.
    public var messageID: String
    public var kind: Kind
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    /// From the sending identity; empty on masked sends.
    public var replyTo: [EmailAddress]
    public var subject: String
    /// The user's own text, in `MailBodyFormatting`'s scope. Quote and signature are not part of it.
    public var body: AttributedString
    public var attachments: [DraftAttachment]
    public var inReplyTo: [String]?
    public var references: [String]?
    /// The message being replied to or forwarded.
    public var original: OriginalMessage?
    /// The quote of a draft written in another client, kept as it was.
    public var preservedTail: PreservedTail?
    /// Whether the From identity's signature goes below the text. Drafts from other clients that had no
    /// recognisable signature block get none, so a signature is never added twice; masked sends never get one.
    public var includesSignature: Bool

    public init(
        id: UUID = UUID(), kind: Kind = .new, from: EmailAddress?, messageID: String? = nil,
        to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], replyTo: [EmailAddress] = [],
        subject: String = "", body: AttributedString = AttributedString(), attachments: [DraftAttachment] = [],
        inReplyTo: [String]? = nil, references: [String]? = nil, original: OriginalMessage? = nil,
        preservedTail: PreservedTail? = nil, includesSignature: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.from = from
        self.messageID = messageID ?? Self.newMessageID(domain: from.flatMap { AddressParser.domain(of: $0.email) })
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.original = original
        self.preservedTail = preservedTail
        self.includesSignature = includesSignature
    }

    /// A fresh Message-ID on `domain`.
    public static func newMessageID(domain: String) -> String {
        newMessageID(domain: Optional(domain))
    }

    /// Without a sender yet, the reserved "invalid" domain stands in until From is set, which replaces the id.
    static func newMessageID(domain: String?) -> String {
        let domain = domain.map { $0.lowercased() }.flatMap { $0.isEmpty ? nil : $0 } ?? "invalid"
        return "\(UUID().uuidString.lowercased())@\(domain)"
    }

    /// The domain part of `messageID`.
    public var messageIDDomain: String? {
        messageID.split(separator: "@").last.map(String.init)
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, messageID, kind, from, to, cc, bcc, replyTo, subject, body, attachments, inReplyTo, references
        case original, preservedTail, includesSignature
    }

    /// The body is stored with its attributes in `MailBodyFormatting`'s scope; fields added later decode with
    /// their defaults, so drafts saved by an older version still open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        messageID = try container.decode(String.self, forKey: .messageID)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .new
        from = try container.decodeIfPresent(EmailAddress.self, forKey: .from)
        to = try container.decodeIfPresent([EmailAddress].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([EmailAddress].self, forKey: .cc) ?? []
        bcc = try container.decodeIfPresent([EmailAddress].self, forKey: .bcc) ?? []
        replyTo = try container.decodeIfPresent([EmailAddress].self, forKey: .replyTo) ?? []
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        body = try container.decodeIfPresent(
            AttributedString.self, forKey: .body, configuration: MailBodyFormatting.Scope.self) ?? AttributedString()
        attachments = try container.decodeIfPresent([DraftAttachment].self, forKey: .attachments) ?? []
        inReplyTo = try container.decodeIfPresent([String].self, forKey: .inReplyTo)
        references = try container.decodeIfPresent([String].self, forKey: .references)
        original = try container.decodeIfPresent(OriginalMessage.self, forKey: .original)
        preservedTail = try container.decodeIfPresent(PreservedTail.self, forKey: .preservedTail)
        includesSignature = try container.decodeIfPresent(Bool.self, forKey: .includesSignature) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encode(bcc, forKey: .bcc)
        try container.encode(replyTo, forKey: .replyTo)
        try container.encode(subject, forKey: .subject)
        try container.encode(body, forKey: .body, configuration: MailBodyFormatting.Scope.self)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
        try container.encodeIfPresent(references, forKey: .references)
        try container.encodeIfPresent(original, forKey: .original)
        try container.encodeIfPresent(preservedTail, forKey: .preservedTail)
        try container.encode(includesSignature, forKey: .includesSignature)
    }
}

/// A file in a draft.
public struct DraftAttachment: Codable, Sendable, Equatable, Identifiable {
    public enum Source: Codable, Sendable, Equatable {
        /// The bytes are on this device, in MailStore's outgoing blob for `id`.
        case local
        /// Already on the server: a forwarded original's attachment, or a file of a draft saved elsewhere.
        case server(blobId: String)
    }

    public var id: UUID
    public var name: String
    /// The MIME type.
    public var type: String
    public var size: Int
    public var source: Source

    public init(id: UUID = UUID(), name: String, type: String, size: Int, source: Source) {
        self.id = id
        self.name = name
        self.type = type
        self.size = size
        self.source = source
    }
}

/// The message a reply or forward is based on.
public struct OriginalMessage: Codable, Sendable, Equatable {
    /// An image the original's HTML shows through a `cid:` URL; it is attached again by blob id.
    public struct InlinePart: Codable, Sendable, Equatable {
        public var cid: String
        public var blobId: String
        public var type: String
        public var name: String?

        public init(cid: String, blobId: String, type: String, name: String? = nil) {
            self.cid = cid
            self.blobId = blobId
            self.type = type
            self.name = name
        }
    }

    public var emailID: String
    /// The whole original message (`message/rfc822`), for forwarding as an attachment.
    public var blobID: String?
    public var quote: QuotedMessage
    public var inlineParts: [InlinePart]

    public init(emailID: String, blobID: String?, quote: QuotedMessage, inlineParts: [InlinePart] = []) {
        self.emailID = emailID
        self.blobID = blobID
        self.quote = quote
        self.inlineParts = inlineParts
    }
}

/// The original as far as the quote needs it. `html` is the original, untrusted markup; it is sanitised when the
/// message is assembled and only ever shown through the CSP-locked message renderer.
public struct QuotedMessage: Codable, Sendable, Equatable {
    public var fromName: String?
    public var fromEmail: String
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date
    public var subject: String
    public var html: String?
    public var text: String?
    /// The server cut the body short, so the quote is incomplete.
    public var isTruncated: Bool

    public init(
        fromName: String?, fromEmail: String, to: [EmailAddress] = [], cc: [EmailAddress] = [], date: Date,
        subject: String, html: String?, text: String?, isTruncated: Bool = false
    ) {
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.to = to
        self.cc = cc
        self.date = date
        self.subject = subject
        self.html = html
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// The quoted part of a draft written in another client (or saved by GoodMail elsewhere), already sanitised and
/// sent on as it is.
public struct PreservedTail: Codable, Sendable, Equatable {
    public var html: String
    public var text: String
    /// Images the tail shows through `cid:` URLs, attached again by blob id.
    public var inlineParts: [OriginalMessage.InlinePart]

    public init(html: String, text: String, inlineParts: [OriginalMessage.InlinePart] = []) {
        self.html = html
        self.text = text
        self.inlineParts = inlineParts
    }

    enum CodingKeys: String, CodingKey { case html, text, inlineParts }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        html = try container.decode(String.self, forKey: .html)
        text = try container.decode(String.self, forKey: .text)
        inlineParts = try container.decodeIfPresent([OriginalMessage.InlinePart].self, forKey: .inlineParts) ?? []
    }
}

/// A sending identity's signature (`htmlSignature`, `textSignature`).
public struct Signature: Codable, Sendable, Equatable {
    public var html: String?
    public var text: String?

    public init(html: String?, text: String?) {
        self.html = html
        self.text = text
    }

    public var isEmpty: Bool {
        (html ?? "").allSatisfy(\.isWhitespace) && (text ?? "").allSatisfy(\.isWhitespace)
    }
}
