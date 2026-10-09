/// RFC 8621 §6: an address the user may send from.
///
/// Decoding is lenient, as Fastmail adds properties of its own and may leave out `name` and `mayDelete`.
/// It is also `Encodable`, so that the identities can be kept for starting offline.
public struct Identity: SettableObject, Codable, Equatable {
    public static let typeName = "Identity"
    public static let capability = Capability.submission

    public let id: String
    public let name: String
    /// An address, or `*@domain` for every address at a domain.
    public let email: String
    public let replyTo: [EmailAddress]?
    public let bcc: [EmailAddress]?
    public let textSignature: String?
    public let htmlSignature: String?
    public let mayDelete: Bool

    public init(
        id: String, name: String = "", email: String, replyTo: [EmailAddress]? = nil, bcc: [EmailAddress]? = nil,
        textSignature: String? = nil, htmlSignature: String? = nil, mayDelete: Bool = false
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.replyTo = replyTo
        self.bcc = bcc
        self.textSignature = textSignature
        self.htmlSignature = htmlSignature
        self.mayDelete = mayDelete
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, email, replyTo, bcc, textSignature, htmlSignature, mayDelete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decode(String.self, forKey: .email)
        replyTo = try container.decodeIfPresent([EmailAddress].self, forKey: .replyTo)
        bcc = try container.decodeIfPresent([EmailAddress].self, forKey: .bcc)
        textSignature = try container.decodeIfPresent(String.self, forKey: .textSignature)
        htmlSignature = try container.decodeIfPresent(String.self, forKey: .htmlSignature)
        mayDelete = try container.decodeIfPresent(Bool.self, forKey: .mayDelete) ?? false
    }

    /// Whether this identity covers a whole domain (`*@domain`).
    public var isWildcard: Bool {
        email.hasPrefix("*@")
    }

    /// Whether mail from `address` may be sent with this identity: its own address, or any address at its
    /// domain for a wildcard identity. Case doesn't matter.
    public func matches(_ address: String) -> Bool {
        guard isWildcard else { return address.lowercased() == email.lowercased() }
        guard let at = address.lastIndex(of: "@"), at != address.startIndex else { return false }
        return address[address.index(after: at)...].lowercased() == email.dropFirst(2).lowercased()
    }

    public struct Create: Encodable, Sendable, Equatable {
        public var name: String
        public var email: String

        public init(name: String = "", email: String) {
            self.name = name
            self.email = email
        }
    }
}

public typealias IdentityGet = GetRequest<Identity>
public typealias IdentitySet = SetRequest<Identity>
