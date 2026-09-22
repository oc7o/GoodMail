/// RFC 8621 §6: an address the user may send from.
public struct Identity: JMAPObject, Equatable {
    public static let typeName = "Identity"
    public static let capability = Capability.submission

    public let id: String
    public let name: String
    public let email: String
    public let replyTo: [EmailAddress]?
    public let bcc: [EmailAddress]?
    public let textSignature: String?
    public let htmlSignature: String?
    public let mayDelete: Bool
}

public typealias IdentityGet = GetRequest<Identity>
