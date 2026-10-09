import Foundation

/// A handle to one call inside a `Batch`, used to build back-references and read its result.
public struct CallHandle<Call: MethodCall>: Sendable {
    public let id: String

    public func reference(_ path: String) -> ResultReference {
        ResultReference(resultOf: id, name: Call.name, path: path)
    }
}

/// Several method calls sent in one HTTP request.
///
/// ```swift
/// var batch = Batch()
/// let query = batch.add(EmailQuery(accountId: id, filter: .condition(.init(inMailbox: inbox))))
/// let get = batch.add(EmailGet(accountId: id, ids: .reference(query.reference("/ids"))))
/// let response = try await client.send(batch)
/// let emails = try response.get(get).list
/// ```
public struct Batch: Sendable {
    fileprivate struct Invocation: Sendable {
        let name: String
        let id: String
        let arguments: any MethodCall
    }

    fileprivate private(set) var invocations: [Invocation] = []
    private(set) var using: Set<String> = [Capability.core]

    public init() {}

    public var isEmpty: Bool { invocations.isEmpty }

    @discardableResult
    public mutating func add<Call: MethodCall>(_ call: Call) -> CallHandle<Call> {
        let id = "c\(invocations.count)"
        invocations.append(Invocation(name: Call.name, id: id, arguments: call))
        using.formUnion(Call.using)
        return CallHandle(id: id)
    }
}

extension Batch: Encodable {
    private enum CodingKeys: String, CodingKey { case using, methodCalls }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(using.sorted(), forKey: .using)
        var calls = container.nestedUnkeyedContainer(forKey: .methodCalls)
        for invocation in invocations {
            var triple = calls.nestedUnkeyedContainer()
            try triple.encode(invocation.name)
            try triple.encode(invocation.arguments)
            try triple.encode(invocation.id)
        }
    }
}

/// The decoded response to a `Batch`.
public struct BatchResponse: Sendable {
    struct Invocation: Sendable {
        let name: String
        let arguments: JSONValue
        let id: String
    }

    let invocations: [Invocation]
    public let sessionState: String

    /// Returns the typed result of a call, or throws its method error.
    ///
    /// Only the first answer with the call's id counts: a call answers once, except that `EmailSubmission/set`
    /// is followed by the answer of the implicit `Email/set` its `onSuccess…` arguments make, which may be an
    /// error of its own (RFC 8621 §7.5).
    public func get<Call: MethodCall>(_ handle: CallHandle<Call>) throws -> Call.Response {
        guard let invocation = invocations.first(where: { $0.id == handle.id }) else {
            throw JMAPError.unexpectedResponse(callId: handle.id)
        }
        if invocation.name == "error" {
            throw JMAPError.method(try Self.decode(MethodError.self, from: invocation.arguments))
        }
        guard invocation.name == Call.name else { throw JMAPError.unexpectedResponse(callId: handle.id) }
        return try Self.decode(Call.Response.self, from: invocation.arguments)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            let data = try JMAPCoding.makeEncoder().encode(value)
            return try JMAPCoding.makeDecoder().decode(T.self, from: data)
        } catch {
            throw JMAPError.decoding("\(T.self): \(error)")
        }
    }
}

extension BatchResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case methodResponses, sessionState }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionState = try container.decode(String.self, forKey: .sessionState)
        var responses = try container.nestedUnkeyedContainer(forKey: .methodResponses)
        var invocations: [Invocation] = []
        while !responses.isAtEnd {
            var triple = try responses.nestedUnkeyedContainer()
            invocations.append(Invocation(
                name: try triple.decode(String.self),
                arguments: try triple.decode(JSONValue.self),
                id: try triple.decode(String.self)))
        }
        self.invocations = invocations
    }
}
