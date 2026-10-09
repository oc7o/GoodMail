import Foundation

/// A JMAP method-level error (RFC 8620 §3.6.2), returned as an `error` invocation.
public struct MethodError: Decodable, Sendable, Equatable, Error {
    public let type: String
    public let description: String?

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }

    public static let cannotCalculateChanges = "cannotCalculateChanges"
    public static let stateMismatch = "stateMismatch"
    public static let tooManyChanges = "tooManyChanges"
    public static let serverUnavailable = "serverUnavailable"
    /// The only method error after which the method may have changed something (RFC 8620 §3.6.2).
    public static let serverPartialFail = "serverPartialFail"
}

/// A per-object failure inside a `/set` response (RFC 8620 §5.3, RFC 8621 §4.6 and §7.5).
public struct SetError: Decodable, Sendable, Equatable, Error {
    public let type: String
    public let description: String?
    public let properties: [String]?
    /// `blobNotFound`: every blob id the server couldn't find.
    public let notFound: [String]?
    /// `tooLarge`: the largest message the server sends, in octets.
    public let maxSize: Int?
    /// `tooManyRecipients`: how many recipients the server allows.
    public let maxRecipients: Int?
    /// `invalidRecipients`: the addresses the server can't send to.
    public let invalidRecipients: [String]?

    public init(
        type: String, description: String? = nil, properties: [String]? = nil, notFound: [String]? = nil,
        maxSize: Int? = nil, maxRecipients: Int? = nil, invalidRecipients: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.notFound = notFound
        self.maxSize = maxSize
        self.maxRecipients = maxRecipients
        self.invalidRecipients = invalidRecipients
    }

    public static let notFound = "notFound"
    public static let forbidden = "forbidden"
    public static let invalidProperties = "invalidProperties"
    public static let overQuota = "overQuota"
    public static let tooLarge = "tooLarge"
    public static let rateLimit = "rateLimit"
    public static let blobNotFound = "blobNotFound"
    public static let invalidEmail = "invalidEmail"
    public static let tooManyRecipients = "tooManyRecipients"
    public static let noRecipients = "noRecipients"
    public static let invalidRecipients = "invalidRecipients"
    public static let forbiddenMailFrom = "forbiddenMailFrom"
    public static let forbiddenFrom = "forbiddenFrom"
    public static let forbiddenToSend = "forbiddenToSend"
    public static let cannotUnsend = "cannotUnsend"
    /// Cyrus's answer to a submission whose email doesn't exist.
    public static let emailNotFound = "emailNotFound"
}

public enum JMAPError: Error, Sendable, Equatable {
    /// Token missing, invalid or revoked (HTTP 401).
    case unauthorized
    /// The server rejected the request (4xx/5xx) with an optional RFC 7807 problem type.
    case http(status: Int, problemType: String?)
    /// The server asked to slow down (HTTP 429), and the request wasn't sent again or retries ran out.
    case rateLimited
    case missingCapability(String)
    case method(MethodError)
    /// A method response for the given call id was missing or had the wrong name.
    case unexpectedResponse(callId: String)
    case decoding(String)
    case transport(String)
    /// The request failed below HTTP: no connection, a timeout, a dropped connection, a failed TLS handshake.
    case connection(URLError.Code, String)
    /// A request that must not run twice (`RetryPolicy.never`) was never sent, because fetching the session it
    /// needs failed with this error, one that on its own would leave open whether the request ran.
    indirect case sessionUnavailable(JMAPError)

    /// The request-level problem type for exceeding a server limit (RFC 8620 §3.6.1).
    public static let limitProblemType = "urn:ietf:params:jmap:error:limit"

    /// Whether the same request may succeed later unchanged (offline, throttled, server trouble).
    ///
    /// A request over a limit counts as temporary because the one requests hit in practice is
    /// `maxConcurrentRequests`.
    public var isTemporary: Bool {
        switch self {
        case .transport, .connection, .rateLimited: true
        case .http(let status, let problemType):
            status == 408 || status == 429 || status >= 500 || problemType == Self.limitProblemType
        case .method(let error): error.type == MethodError.serverUnavailable
        case .sessionUnavailable(let error): error.isTemporary
        default: false
        }
    }

    /// Whether the server may have received and acted on the request although no usable answer arrived.
    ///
    /// Requests that must not run twice, such as sending mail, are only repeated when this is false. It is
    /// false only when the server certainly didn't run the request: it never got there (no connection, no
    /// host, a failed TLS handshake, no session to send it with), or the server answered that it refused it
    /// (a 429, a 4xx other than 408, a rejected token). A 503 may come after the work, so it counts as reached.
    /// A method error means that method changed nothing, unless it is `serverPartialFail`.
    public var mayHaveReachedServer: Bool {
        switch self {
        case .connection(let code, _): !Self.codesOfRequestsNeverSent.contains(code)
        case .http(let status, _): status == 408 || !(400..<500).contains(status)
        case .rateLimited, .unauthorized, .missingCapability, .sessionUnavailable: false
        case .method(let error): error.type == MethodError.serverPartialFail
        case .transport, .decoding, .unexpectedResponse: true
        }
    }

    /// Failures that happen before any byte of the request reaches the server.
    private static let codesOfRequestsNeverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
        .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
    ]
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
        case .transport(let message), .connection(_, let message):
            message
        case .sessionUnavailable(let error):
            error.errorDescription
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
