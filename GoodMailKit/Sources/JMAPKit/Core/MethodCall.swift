import Foundation

/// A JMAP data type such as `Mailbox`, `Email` or `MaskedEmail`.
public protocol JMAPObject: Decodable, Sendable, Identifiable where ID == String {
    /// The type name used to form method names, e.g. `"Mailbox"` → `Mailbox/get`.
    static var typeName: String { get }
    /// The capability that must be listed in `using` to call methods on this type.
    static var capability: String { get }
}

/// A single typed JMAP method invocation.
public protocol MethodCall: Encodable, Sendable {
    associatedtype Response: Decodable & Sendable
    static var name: String { get }
    static var using: [String] { get }
}

/// A back-reference to the result of an earlier call in the same request (RFC 8620 §3.7).
public struct ResultReference: Encodable, Sendable, Equatable {
    public let resultOf: String
    public let name: String
    public let path: String

    public init(resultOf: String, name: String, path: String) {
        self.resultOf = resultOf
        self.name = name
        self.path = path
    }
}

/// Either literal ids or a back-reference producing ids.
public enum IDs: Sendable, Equatable {
    case all
    case ids([String])
    case reference(ResultReference)
}

extension IDs: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: String...) { self = .ids(elements) }
}

extension KeyedEncodingContainer {
    /// Encodes `ids` as `"key": [...]`, `"key": null` or `"#key": {ref}`.
    mutating func encode(_ ids: IDs, forKey key: Key, referenceKey: Key) throws {
        switch ids {
        case .all: try encodeNil(forKey: key)
        case .ids(let values): try encode(values, forKey: key)
        case .reference(let ref): try encode(ref, forKey: referenceKey)
        }
    }
}
