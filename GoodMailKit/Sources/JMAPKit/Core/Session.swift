import Foundation

/// The JMAP Session resource (RFC 8620 §2).
public struct Session: Decodable, Sendable, Equatable {
    public struct Account: Decodable, Sendable, Equatable {
        public let name: String
        public let isPersonal: Bool
        public let isReadOnly: Bool
        public let accountCapabilities: [String: JSONValue]
    }

    public let capabilities: [String: JSONValue]
    public let accounts: [String: Account]
    public let primaryAccounts: [String: String]
    public let username: String
    public let apiUrl: URL
    /// RFC 6570 template with `{accountId}`, `{blobId}`, `{type}`, `{name}`.
    public let downloadUrl: String
    /// RFC 6570 template with `{accountId}`.
    public let uploadUrl: String
    /// RFC 6570 template with `{types}`, `{closeafter}`, `{ping}`.
    public let eventSourceUrl: String
    public let state: String

    public func supports(_ capability: String) -> Bool {
        capabilities[capability] != nil
    }

    /// The primary account for a capability, e.g. `Capability.mail`.
    public func primaryAccountId(for capability: String) throws(JMAPError) -> String {
        guard let id = primaryAccounts[capability] else {
            throw .missingCapability(capability)
        }
        return id
    }

    public func downloadURL(accountId: String, blobId: String, type: String, name: String) -> URL? {
        URL(string: downloadUrl
            .replacingOccurrences(of: "{accountId}", with: Self.escape(accountId))
            .replacingOccurrences(of: "{blobId}", with: Self.escape(blobId))
            .replacingOccurrences(of: "{type}", with: Self.escape(type))
            .replacingOccurrences(of: "{name}", with: Self.escape(name)))
    }

    public func uploadURL(accountId: String) -> URL? {
        URL(string: uploadUrl.replacingOccurrences(of: "{accountId}", with: Self.escape(accountId)))
    }

    /// The URL to receive pushed changes from (RFC 8620 §7.3).
    ///
    /// - Parameters:
    ///   - types: The type names to hear about, such as `"Email"`; all types when empty.
    ///   - closeAfterState: Whether the server ends the response after each change, for buffering proxies.
    ///   - ping: Seconds between the server's keep-alive pings; 0 for none.
    ///
    /// Variables missing from the server's template are added as query items.
    public func eventSourceURL(types: [String], closeAfterState: Bool = false, ping: Int) -> URL? {
        var template = eventSourceUrl
        var missing: [URLQueryItem] = []
        for (name, value) in [
            ("types", types.isEmpty ? "*" : types.joined(separator: ",")),
            ("closeafter", closeAfterState ? "state" : "no"),
            ("ping", String(ping)),
        ] {
            if template.contains("{\(name)}") {
                template = template.replacingOccurrences(of: "{\(name)}", with: Self.escape(value))
            } else {
                missing.append(URLQueryItem(name: name, value: value))
            }
        }
        guard var components = URLComponents(string: template) else { return nil }
        if !missing.isEmpty {
            components.queryItems = (components.queryItems ?? []) + missing
        }
        return components.url
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? value
    }
}

/// The server's limits (RFC 8620 §2, `urn:ietf:params:jmap:core`).
public struct CoreCapabilities: Decodable, Sendable, Equatable {
    public let maxSizeUpload: Int
    public let maxConcurrentUpload: Int
    public let maxSizeRequest: Int
    public let maxConcurrentRequests: Int
    public let maxCallsInRequest: Int
    public let maxObjectsInGet: Int
    public let maxObjectsInSet: Int

    public init(
        maxSizeUpload: Int, maxConcurrentUpload: Int, maxSizeRequest: Int, maxConcurrentRequests: Int,
        maxCallsInRequest: Int, maxObjectsInGet: Int, maxObjectsInSet: Int
    ) {
        self.maxSizeUpload = maxSizeUpload
        self.maxConcurrentUpload = maxConcurrentUpload
        self.maxSizeRequest = maxSizeRequest
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxCallsInRequest = maxCallsInRequest
        self.maxObjectsInGet = maxObjectsInGet
        self.maxObjectsInSet = maxObjectsInSet
    }
}

/// A mail account's limits (RFC 8621 §1.3.1).
public struct MailAccountCapabilities: Decodable, Sendable, Equatable {
    /// The total size of the attachments of one email, in octets, as their decoded size.
    public let maxSizeAttachmentsPerEmail: Int?
    public let maxMailboxesPerEmail: Int?

    public init(maxSizeAttachmentsPerEmail: Int?, maxMailboxesPerEmail: Int?) {
        self.maxSizeAttachmentsPerEmail = maxSizeAttachmentsPerEmail
        self.maxMailboxesPerEmail = maxMailboxesPerEmail
    }
}

/// What a submission account supports (RFC 8621 §1.3.2).
public struct SubmissionAccountCapabilities: Decodable, Sendable, Equatable {
    /// The longest a submission may be held before release, in seconds; 0 when delayed sending isn't supported.
    public let maxDelayedSend: Int
    /// SMTP extensions the server announces, by EHLO keyword.
    public let submissionExtensions: [String: [String]]

    public init(maxDelayedSend: Int, submissionExtensions: [String: [String]]) {
        self.maxDelayedSend = maxDelayedSend
        self.submissionExtensions = submissionExtensions
    }
}

extension Session {
    public var coreCapabilities: CoreCapabilities? {
        capabilities[Capability.core].flatMap(Self.decode)
    }

    public func mailCapabilities(accountId: String) -> MailAccountCapabilities? {
        accounts[accountId]?.accountCapabilities[Capability.mail].flatMap(Self.decode)
    }

    public func submissionCapabilities(accountId: String) -> SubmissionAccountCapabilities? {
        accounts[accountId]?.accountCapabilities[Capability.submission].flatMap(Self.decode)
    }

    /// Whether this session may send mail: the token has the submission scope and its account isn't read-only.
    public var canSubmit: Bool {
        guard supports(Capability.submission), let id = primaryAccounts[Capability.submission],
              let account = accounts[id]
        else { return false }
        return !account.isReadOnly
    }

    private static func decode<T: Decodable>(_ value: JSONValue) -> T? {
        guard let data = try? JMAPCoding.makeEncoder().encode(value) else { return nil }
        return try? JMAPCoding.makeDecoder().decode(T.self, from: data)
    }
}
