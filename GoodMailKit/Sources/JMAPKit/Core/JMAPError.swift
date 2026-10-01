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

extension JMAPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Fastmail no longer accepts this API token."
        case .http(let status, let problemType):
            "Fastmail returned an error (HTTP \(status)\(problemType.map { ", \($0)" } ?? ""))."
        case .rateLimited:
            "Fastmail is rate limiting requests. Try again in a moment."
        case .missingCapability(let capability):
            "This account doesn't offer \(capability)."
        case .method(let error):
            error.errorDescription
        case .unexpectedResponse:
            "Fastmail sent an incomplete response."
        case .decoding(let details):
            "Couldn't read Fastmail's response (\(details))."
        case .transport(let message):
            message
        }
    }
}

extension MethodError: LocalizedError {
    public var errorDescription: String? {
        "Fastmail rejected the request: \(description ?? type)."
    }
}

extension SetError: LocalizedError {
    public var errorDescription: String? {
        "Fastmail couldn't apply the change: \(description ?? type)."
    }
}
