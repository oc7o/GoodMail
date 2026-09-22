import Foundation

/// RFC 8621 §4. All properties besides `id` are optional because callers choose which to fetch.
public struct Email: QueryableObject, Equatable {
    public static let typeName = "Email"
    public static let capability = Capability.mail

    public let id: String
    public let blobId: String?
    public let threadId: String?
    public let mailboxIds: [String: Bool]?
    public let keywords: [String: Bool]?
    public let size: Int?
    public let receivedAt: Date?

    public let messageId: [String]?
    public let inReplyTo: [String]?
    public let references: [String]?
    public let sender: [EmailAddress]?
    public let from: [EmailAddress]?
    public let to: [EmailAddress]?
    public let cc: [EmailAddress]?
    public let bcc: [EmailAddress]?
    public let replyTo: [EmailAddress]?
    public let subject: String?
    public let sentAt: Date?

    public let hasAttachment: Bool?
    public let preview: String?
    public let bodyValues: [String: EmailBodyValue]?
    public let textBody: [EmailBodyPart]?
    public let htmlBody: [EmailBodyPart]?
    public let attachments: [EmailBodyPart]?

    /// `List-Unsubscribe` (RFC 2369) parsed as URLs, e.g. `mailto:` and `https:`.
    public let listUnsubscribe: [String]?
    /// `List-Unsubscribe-Post` (RFC 8058); `List-Unsubscribe=One-Click` enables one-click unsubscribe.
    public let listUnsubscribePost: String?

    enum CodingKeys: String, CodingKey {
        case id, blobId, threadId, mailboxIds, keywords, size, receivedAt
        case messageId, inReplyTo, references, sender, from, to, cc, bcc, replyTo, subject, sentAt
        case hasAttachment, preview, bodyValues, textBody, htmlBody, attachments
        case listUnsubscribe = "header:List-Unsubscribe:asURLs"
        case listUnsubscribePost = "header:List-Unsubscribe-Post:asText"
    }

    public func has(_ keyword: Keyword) -> Bool {
        keywords?[keyword.rawValue] == true
    }

    public struct Keyword: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let seen = Keyword(rawValue: "$seen")
        public static let flagged = Keyword(rawValue: "$flagged")
        public static let draft = Keyword(rawValue: "$draft")
        public static let answered = Keyword(rawValue: "$answered")
        public static let forwarded = Keyword(rawValue: "$forwarded")
        public static let junk = Keyword(rawValue: "$junk")
        public static let notJunk = Keyword(rawValue: "$notjunk")
        public static let phishing = Keyword(rawValue: "$phishing")
    }

    /// Property sets to request with `Email/get`.
    public enum Properties {
        /// Enough to render a message list row.
        public static let listing = [
            "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt",
            "from", "to", "subject", "sentAt", "hasAttachment", "preview",
        ]
        /// Everything needed to display a message.
        public static let full = listing + [
            "messageId", "inReplyTo", "references", "sender", "cc", "bcc", "replyTo",
            "bodyValues", "textBody", "htmlBody", "attachments",
            CodingKeys.listUnsubscribe.rawValue, CodingKeys.listUnsubscribePost.rawValue,
        ]
    }

    /// RFC 8621 §4.4.1.
    public struct FilterCondition: Encodable, Sendable, Equatable {
        public var inMailbox: String?
        public var inMailboxOtherThan: [String]?
        public var before: Date?
        public var after: Date?
        public var minSize: Int?
        public var maxSize: Int?
        public var allInThreadHaveKeyword: String?
        public var someInThreadHaveKeyword: String?
        public var noneInThreadHaveKeyword: String?
        public var hasKeyword: String?
        public var notKeyword: String?
        public var hasAttachment: Bool?
        public var text: String?
        public var from: String?
        public var to: String?
        public var cc: String?
        public var bcc: String?
        public var subject: String?
        public var body: String?
        /// `[name]` tests for presence, `[name, value]` for containment.
        public var header: [String]?

        public init(
            inMailbox: String? = nil, inMailboxOtherThan: [String]? = nil,
            before: Date? = nil, after: Date? = nil, minSize: Int? = nil, maxSize: Int? = nil,
            allInThreadHaveKeyword: String? = nil, someInThreadHaveKeyword: String? = nil,
            noneInThreadHaveKeyword: String? = nil, hasKeyword: String? = nil, notKeyword: String? = nil,
            hasAttachment: Bool? = nil, text: String? = nil, from: String? = nil, to: String? = nil,
            cc: String? = nil, bcc: String? = nil, subject: String? = nil, body: String? = nil,
            header: [String]? = nil
        ) {
            self.inMailbox = inMailbox
            self.inMailboxOtherThan = inMailboxOtherThan
            self.before = before
            self.after = after
            self.minSize = minSize
            self.maxSize = maxSize
            self.allInThreadHaveKeyword = allInThreadHaveKeyword
            self.someInThreadHaveKeyword = someInThreadHaveKeyword
            self.noneInThreadHaveKeyword = noneInThreadHaveKeyword
            self.hasKeyword = hasKeyword
            self.notKeyword = notKeyword
            self.hasAttachment = hasAttachment
            self.text = text
            self.from = from
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = subject
            self.body = body
            self.header = header
        }
    }
}

public struct EmailAddress: Codable, Sendable, Hashable {
    public let name: String?
    public let email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }
}

public struct EmailBodyValue: Codable, Sendable, Equatable {
    public let value: String
    public let isEncodingProblem: Bool
    public let isTruncated: Bool
}

public struct EmailBodyPart: Codable, Sendable, Equatable {
    public let partId: String?
    public let blobId: String?
    public let size: Int?
    public let name: String?
    public let type: String?
    public let charset: String?
    public let disposition: String?
    public let cid: String?
    public let subParts: [EmailBodyPart]?
}

/// `Email/get` with body-fetching options (RFC 8621 §4.2).
public struct EmailGet: MethodCall {
    public typealias Response = GetResponse<Email>
    public static let name = "Email/get"
    public static let using = [Capability.mail]

    public var accountId: String
    public var ids: IDs
    public var properties: [String]?
    public var fetchTextBodyValues: Bool?
    public var fetchHTMLBodyValues: Bool?
    public var maxBodyValueBytes: Int?

    public init(
        accountId: String,
        ids: IDs,
        properties: [String]? = Email.Properties.listing,
        fetchTextBodyValues: Bool? = nil,
        fetchHTMLBodyValues: Bool? = nil,
        maxBodyValueBytes: Int? = nil
    ) {
        self.accountId = accountId
        self.ids = ids
        self.properties = properties
        self.fetchTextBodyValues = fetchTextBodyValues
        self.fetchHTMLBodyValues = fetchHTMLBodyValues
        self.maxBodyValueBytes = maxBodyValueBytes
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, ids, properties, fetchTextBodyValues, fetchHTMLBodyValues, maxBodyValueBytes
        case idsRef = "#ids"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(ids, forKey: .ids, referenceKey: .idsRef)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(fetchTextBodyValues, forKey: .fetchTextBodyValues)
        try container.encodeIfPresent(fetchHTMLBodyValues, forKey: .fetchHTMLBodyValues)
        try container.encodeIfPresent(maxBodyValueBytes, forKey: .maxBodyValueBytes)
    }
}

public typealias EmailQuery = QueryRequest<Email>
public typealias EmailChanges = ChangesRequest<Email>
