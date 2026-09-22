import Foundation

/// RFC 8621 §2.
public struct Mailbox: QueryableObject, Equatable {
    public static let typeName = "Mailbox"
    public static let capability = Capability.mail

    public struct Role: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let inbox = Role(rawValue: "inbox")
        public static let archive = Role(rawValue: "archive")
        public static let drafts = Role(rawValue: "drafts")
        public static let sent = Role(rawValue: "sent")
        public static let junk = Role(rawValue: "junk")
        public static let trash = Role(rawValue: "trash")
    }

    public struct FilterCondition: Encodable, Sendable {
        public var parentId: String?
        public var name: String?
        public var role: Role?
        public var hasAnyRole: Bool?
        public var isSubscribed: Bool?

        public init(parentId: String? = nil, name: String? = nil, role: Role? = nil,
                    hasAnyRole: Bool? = nil, isSubscribed: Bool? = nil) {
            self.parentId = parentId
            self.name = name
            self.role = role
            self.hasAnyRole = hasAnyRole
            self.isSubscribed = isSubscribed
        }
    }

    public let id: String
    public let name: String
    public let parentId: String?
    public let role: Role?
    public let sortOrder: Int
    public let totalEmails: Int
    public let unreadEmails: Int
    public let totalThreads: Int
    public let unreadThreads: Int
    public let isSubscribed: Bool
}

public typealias MailboxGet = GetRequest<Mailbox>
public typealias MailboxChanges = ChangesRequest<Mailbox>
public typealias MailboxQuery = QueryRequest<Mailbox>
