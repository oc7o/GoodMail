import Foundation

/// A new email for `Email/set`, such as a draft or a message about to be sent (RFC 8621 §4.6).
///
/// Properties left `nil` are left out, so the server uses its defaults; without a `messageId` it makes one up.
public struct EmailCreate: Encodable, Sendable, Equatable {
    public var mailboxIds: [String: Bool]
    public var keywords: [String: Bool]
    /// Without angle brackets.
    public var messageId: [String]?
    public var inReplyTo: [String]?
    public var references: [String]?
    public var from: [EmailAddress]?
    public var to: [EmailAddress]?
    public var cc: [EmailAddress]?
    public var bcc: [EmailAddress]?
    public var replyTo: [EmailAddress]?
    public var subject: String?
    /// Encoded in UTC, like every date `JMAPCoding` writes.
    public var sentAt: Date?
    public var bodyStructure: EmailBodyPartCreate
    public var bodyValues: [String: EmailBodyValueCreate]

    public init(
        mailboxIds: [String: Bool], keywords: [String: Bool], messageId: [String]?, inReplyTo: [String]? = nil,
        references: [String]? = nil, from: [EmailAddress]?, to: [EmailAddress]?, cc: [EmailAddress]? = nil,
        bcc: [EmailAddress]? = nil, replyTo: [EmailAddress]? = nil, subject: String?, sentAt: Date?,
        bodyStructure: EmailBodyPartCreate, bodyValues: [String: EmailBodyValueCreate]
    ) {
        self.mailboxIds = mailboxIds
        self.keywords = keywords
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.sentAt = sentAt
        self.bodyStructure = bodyStructure
        self.bodyValues = bodyValues
    }

    /// The body of a message with a plain-text and an HTML version:
    /// `mixed( alternative( text/plain, related( text/html, inline… ) ), attachments… )`.
    ///
    /// A wrapper that would hold only one part is left out, so a message without attachments and inline
    /// images is just the `multipart/alternative`. The text and HTML are the body values `"text"` and `"html"`.
    public static func body(
        text: String, html: String, inline: [EmailBodyPartCreate], attachments: [EmailBodyPartCreate]
    ) -> (structure: EmailBodyPartCreate, values: [String: EmailBodyValueCreate]) {
        let textPart = EmailBodyPartCreate(partId: "text", type: "text/plain")
        let htmlPart = EmailBodyPartCreate(partId: "html", type: "text/html")
        let rich = inline.isEmpty ? htmlPart : .multipart("related", [htmlPart] + inline)
        let alternative = EmailBodyPartCreate.multipart("alternative", [textPart, rich])
        let structure = attachments.isEmpty ? alternative : .multipart("mixed", [alternative] + attachments)
        return (structure, ["text": EmailBodyValueCreate(value: text), "html": EmailBodyValueCreate(value: html)])
    }
}

/// One part of the body of a new email: its content comes either from `bodyValues` (`partId`) or from a blob
/// (`blobId`), such as an upload or an attachment of another email.
public struct EmailBodyPartCreate: Encodable, Sendable, Equatable {
    public var partId: String?
    public var blobId: String?
    public var type: String
    public var name: String?
    /// `"attachment"` or `"inline"`.
    public var disposition: String?
    /// Without angle brackets.
    public var cid: String?
    /// Only with `blobId`: the server picks the charset of a part from `bodyValues` itself.
    public var charset: String?
    public var subParts: [EmailBodyPartCreate]?

    public init(
        partId: String? = nil, blobId: String? = nil, type: String, name: String? = nil, disposition: String? = nil,
        cid: String? = nil, charset: String? = nil, subParts: [EmailBodyPartCreate]? = nil
    ) {
        self.partId = partId
        self.blobId = blobId
        self.type = type
        self.name = name
        self.disposition = disposition
        self.cid = cid
        self.charset = charset
        self.subParts = subParts
    }

    public static func blob(
        _ blobId: String, type: String, name: String?, disposition: String, cid: String? = nil
    ) -> Self {
        Self(blobId: blobId, type: type, name: name, disposition: disposition, cid: cid)
    }

    /// A `multipart/{subtype}` part, such as `multipart/mixed`.
    public static func multipart(_ subtype: String, _ parts: [EmailBodyPartCreate]) -> Self {
        Self(type: "multipart/\(subtype)", subParts: parts)
    }
}

public struct EmailBodyValueCreate: Encodable, Sendable, Equatable {
    public var value: String

    public init(value: String) {
        self.value = value
    }
}
