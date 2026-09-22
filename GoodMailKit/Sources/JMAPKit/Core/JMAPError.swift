import Foundation

/// A JMAP method-level error (RFC 8620 §3.6.2), returned as an `error` invocation.
public struct MethodError: Decodable, Sendable, Equatable, Error {
    public let type: String
    public let description: String?

    public static let cannotCalculateChanges = "cannotCalculateChanges"
    public static let stateMismatch = "stateMismatch"
    public static let tooManyChanges = "tooManyChanges"
}

/// A per-object failure inside a `/set` response (RFC 8620 §5.3).
public struct SetError: Decodable, Sendable, Equatable, Error {
    public let type: String
    public let description: String?
    public let properties: [String]?
}

public enum JMAPError: Error, Sendable, Equatable {
    /// Token missing, invalid or revoked (HTTP 401).
    case unauthorized
    /// The server rejected the request (4xx/5xx) with an optional RFC 7807 problem type.
    case http(status: Int, problemType: String?)
    /// Server asked us to slow down and retries were exhausted.
    case rateLimited
    case missingCapability(String)
    case method(MethodError)
    /// A method response for the given call id was missing or had the wrong name.
    case unexpectedResponse(callId: String)
    case decoding(String)
    case transport(String)
}
