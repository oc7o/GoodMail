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

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? value
    }
}
