import Foundation

/// An arbitrary JSON value. Used for untyped method arguments and patch objects.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A JMAP PatchObject: JSON pointer paths mapped to new values (`null` removes the property).
public typealias PatchObject = [String: JSONValue]

extension PatchObject {
    /// A single patch equivalent to applying `self`, then `later`.
    ///
    /// JMAP rejects a patch that sets both a property and a path inside it, so instead of keeping both,
    /// a later path is folded into an earlier value of one of its ancestors, and a later value drops
    /// earlier paths inside it.
    public func merging(_ later: PatchObject) -> PatchObject {
        var merged = self
        for (path, value) in later {
            merged = merged.filter { !$0.key.hasPrefix(path + "/") }
            if let ancestor = merged.keys.first(where: { path.hasPrefix($0 + "/") }) {
                let tokens = path.dropFirst(ancestor.count + 1).split(separator: "/", omittingEmptySubsequences: false)
                merged[ancestor] = merged[ancestor]?.setting(tokens.map { JSONPointer.unescape(String($0)) }, to: value)
            } else {
                merged[path] = value
            }
        }
        return merged
    }
}

extension JSONValue {
    /// The value with the member at `tokens` replaced (or removed, for `null`) as a patch would do it.
    fileprivate func setting(_ tokens: some Collection<String>, to value: JSONValue) -> JSONValue {
        guard let token = tokens.first else { return value }
        var object: [String: JSONValue] = if case .object(let object) = self { object } else { [:] }
        let rest = tokens.dropFirst()
        if rest.isEmpty, value == .null {
            object[token] = nil
        } else {
            object[token] = (object[token] ?? .null).setting(rest, to: value)
        }
        return .object(object)
    }
}
