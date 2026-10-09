import Foundation

/// Fastmail's Masked Email: a unique forwarding address per site.
///
/// See https://www.fastmail.com/developer/maskedemail/
public struct MaskedEmail: SettableObject, Encodable, Equatable {
    public static let typeName = "MaskedEmail"
    public static let capability = Capability.maskedEmail

    public struct State: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Created but not yet used; auto-deleted by Fastmail after 24h without mail.
        public static let pending = State(rawValue: "pending")
        public static let enabled = State(rawValue: "enabled")
        /// Mail is delivered straight to Trash.
        public static let disabled = State(rawValue: "disabled")
        /// Mail is rejected. Can be re-enabled.
        public static let deleted = State(rawValue: "deleted")
    }

    public let id: String
    public let email: String
    public let state: State
    /// Origin the address was made for, e.g. `https://example.com`.
    public let forDomain: String?
    public let description: String?
    public let url: String?
    public let emailPrefix: String?
    public let createdBy: String?
    public let createdAt: Date?
    public let lastMessageAt: Date?

    public struct Create: Encodable, Sendable, Equatable {
        public var state: State?
        public var forDomain: String?
        public var description: String?
        public var url: String?
        /// Up to 64 chars of `a-z`, `0-9` and `_`.
        public var emailPrefix: String?

        public init(state: State? = .enabled, forDomain: String? = nil, description: String? = nil,
                    url: String? = nil, emailPrefix: String? = nil) {
            self.state = state
            self.forDomain = forDomain
            self.description = description
            self.url = url
            self.emailPrefix = emailPrefix
        }
    }

    public static func isValidPrefix(_ prefix: String) -> Bool {
        (1...64).contains(prefix.count)
            && prefix.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}

public typealias MaskedEmailGet = GetRequest<MaskedEmail>
public typealias MaskedEmailSet = SetRequest<MaskedEmail>

extension JMAPClient {
    /// All masked emails in the primary account.
    public func maskedEmails() async throws -> [MaskedEmail] {
        let accountId = try await accountId(for: Capability.maskedEmail)
        return try await call(MaskedEmailGet(accountId: accountId)).list
    }

    /// Creates a masked email and returns it with server-set fields (`id`, `email`, …).
    public func createMaskedEmail(_ create: MaskedEmail.Create) async throws -> MaskedEmail {
        let accountId = try await accountId(for: Capability.maskedEmail)
        let response = try await call(MaskedEmailSet(accountId: accountId, create: ["new": create]))
        if let error = response.notCreated?["new"] { throw error }
        guard let partial = try response.created("new", as: CreatedMaskedEmail.self) else {
            throw JMAPError.unexpectedResponse(callId: "new")
        }
        return MaskedEmail(
            id: partial.id, email: partial.email, state: partial.state ?? create.state ?? .pending,
            forDomain: create.forDomain, description: create.description, url: create.url,
            emailPrefix: create.emailPrefix, createdBy: partial.createdBy, createdAt: partial.createdAt,
            lastMessageAt: nil)
    }

    /// Changes state (enable/disable/delete) or metadata of an existing masked email.
    public func updateMaskedEmail(id: String, _ patch: PatchObject) async throws {
        let accountId = try await accountId(for: Capability.maskedEmail)
        let response = try await call(MaskedEmailSet(accountId: accountId, update: [id: patch]))
        if let error = response.notUpdated?[id] { throw error }
    }

    public func setMaskedEmailState(id: String, _ state: MaskedEmail.State) async throws {
        try await updateMaskedEmail(id: id, ["state": .string(state.rawValue)])
    }

    private struct CreatedMaskedEmail: Decodable {
        let id: String
        let email: String
        let state: MaskedEmail.State?
        let createdBy: String?
        let createdAt: Date?
    }
}
