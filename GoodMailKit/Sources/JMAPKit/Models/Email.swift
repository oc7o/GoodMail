import Foundation

/// RFC 8621 §4. All properties besides `id` are optional because callers choose which to fetch.
public struct Email: QueryableObject, Equatable, Encodable {
    public static let typeName = "Email"
    public static let capability = Capability.mail

    public let id: String
    public let blobId: String?
    public let threadId: String?
    public internal(set) var mailboxIds: [String: Bool]?
    public internal(set) var keywords: [String: Bool]?
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
    public internal(set) var bodyValues: [String: EmailBodyValue]?
    public internal(set) var textBody: [EmailBodyPart]?
    public internal(set) var htmlBody: [EmailBodyPart]?
    public internal(set) var attachments: [EmailBodyPart]?

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

    /// Whether the body was fetched along with the email.
    public var hasBody: Bool { bodyValues != nil }

    /// The email reduced to what a list row needs, for compact storage.
    public func strippingBody() -> Email {
        var email = self
        email.bodyValues = nil
        email.textBody = nil
        email.htmlBody = nil
        email.attachments = nil
        return email
    }

    /// This email with the keywords and mailboxes of `other`: the only properties that ever change
    /// after delivery (RFC 8621 §4), so a stored body stays valid forever.
    public func withFlags(of other: Email) -> Email {
        var email = self
        email.keywords = other.keywords
        email.mailboxIds = other.mailboxIds
        return email
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

extension Email: SettableObject {
    /// Untyped until compose lands: only `update` and `destroy` are used so far.
    public typealias Create = JSONValue

    /// The email as it will look once the server has applied `patch` to its keywords and mailboxes.
    public func applying(_ patch: PatchObject) -> Email {
        var email = self
        for (path, value) in patch {
            let components = path.split(separator: "/", maxSplits: 1).map(String.init)
            let key = components.count == 2 ? JSONPointer.unescape(components[1]) : nil
            switch components[0] {
            case "keywords": email.keywords = Self.patched(email.keywords, key: key, value: value)
            case "mailboxIds": email.mailboxIds = Self.patched(email.mailboxIds, key: key, value: value)
            default: break
            }
        }
        return email
    }

    private static func patched(_ flags: [String: Bool]?, key: String?, value: JSONValue) -> [String: Bool]? {
        guard let key else {
            guard case .object(let object) = value else { return flags }
            return object.compactMapValues { $0 == .bool(true) ? true : nil }
        }
        var flags = flags ?? [:]
        flags[key] = value == .bool(true) ? true : nil
        return flags
    }
}

extension PatchObject {
    public static func setKeyword(_ keyword: Email.Keyword, _ isSet: Bool) -> PatchObject {
        ["keywords/\(JSONPointer.escape(keyword.rawValue))": isSet ? .bool(true) : .null]
    }

    /// Adds the email to `destination`, taking it out of `source` if given.
    public static func move(from source: String? = nil, to destination: String) -> PatchObject {
        var patch: PatchObject = ["mailboxIds/\(JSONPointer.escape(destination))": .bool(true)]
        if let source, source != destination {
            patch["mailboxIds/\(JSONPointer.escape(source))"] = .null
        }
        return patch
    }

    /// Puts the email in `destination` and removes it from every other mailbox.
    public static func moveExclusively(to destination: String) -> PatchObject {
        ["mailboxIds": .object([destination: .bool(true)])]
    }
}

/// RFC 6901 token escaping, as required for PatchObject paths.
enum JSONPointer {
    static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    static func unescape(_ token: String) -> String {
        token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

public typealias EmailQuery = QueryRequest<Email>
public typealias EmailChanges = ChangesRequest<Email>
public typealias EmailSet = SetRequest<Email>
