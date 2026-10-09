import Foundation

/// RFC 8621 §7: an email on its way to its recipients.
///
/// Fastmail deletes a submission once it is released or cancelled, so only held ones can be fetched.
public struct EmailSubmission: QueryableObject, Equatable {
    public static let typeName = "EmailSubmission"
    public static let capability = Capability.submission

    public enum UndoStatus: String, Codable, Sendable {
        /// Held, and may still be cancelled.
        case pending
        /// Released to the recipients.
        case final
        case canceled
    }

    /// An SMTP envelope address with its parameters, such as `HOLDFOR` (RFC 4865).
    public struct Address: Codable, Sendable, Equatable {
        public var email: String
        /// A `nil` value is a parameter without a value; `nil` parameters are written as JSON `null`.
        public var parameters: [String: String?]?

        public init(email: String, parameters: [String: String?]? = nil) {
            self.email = email
            self.parameters = parameters
        }

        private enum CodingKeys: String, CodingKey { case email, parameters }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(email, forKey: .email)
            try container.encode(parameters, forKey: .parameters)
        }
    }

    public struct Envelope: Codable, Sendable, Equatable {
        public var mailFrom: Address
        public var rcptTo: [Address]

        public init(mailFrom: Address, rcptTo: [Address]) {
            self.mailFrom = mailFrom
            self.rcptTo = rcptTo
        }
    }

    public struct Create: Encodable, Sendable, Equatable {
        public var identityId: String
        /// An email id, or `#` and the creation id of an email created earlier in the same request.
        public var emailId: String
        /// Without one, the server takes the envelope from the message's headers.
        public var envelope: Envelope?

        public init(identityId: String, emailId: String, envelope: Envelope?) {
            self.identityId = identityId
            self.emailId = emailId
            self.envelope = envelope
        }
    }

    /// RFC 8621 §7.3.
    public struct FilterCondition: Encodable, Sendable, Equatable {
        public var identityIds: [String]?
        public var emailIds: [String]?
        public var threadIds: [String]?
        public var undoStatus: UndoStatus?
        /// Compares with `sendAt`.
        public var before: Date?
        public var after: Date?

        public init(
            identityIds: [String]? = nil, emailIds: [String]? = nil, threadIds: [String]? = nil,
            undoStatus: UndoStatus? = nil, before: Date? = nil, after: Date? = nil
        ) {
            self.identityIds = identityIds
            self.emailIds = emailIds
            self.threadIds = threadIds
            self.undoStatus = undoStatus
            self.before = before
            self.after = after
        }
    }

    public let id: String
    public let identityId: String?
    public let emailId: String?
    public let threadId: String?
    public let envelope: Envelope?
    /// When the server releases or released it.
    public let sendAt: Date?
    public let undoStatus: UndoStatus?

    public init(
        id: String, identityId: String? = nil, emailId: String? = nil, threadId: String? = nil,
        envelope: Envelope? = nil, sendAt: Date? = nil, undoStatus: UndoStatus? = nil
    ) {
        self.id = id
        self.identityId = identityId
        self.emailId = emailId
        self.threadId = threadId
        self.envelope = envelope
        self.sendAt = sendAt
        self.undoStatus = undoStatus
    }
}

/// `EmailSubmission/set` (RFC 8621 §7.5), which unlike other `/set` methods can also update or destroy the
/// submitted emails once it succeeded.
public struct EmailSubmissionSet: MethodCall {
    public typealias Response = SetResponse
    public static let name = "EmailSubmission/set"
    /// The `onSuccess…` arguments change emails, which needs the mail capability too.
    public static let using = [Capability.submission, Capability.mail]

    public var accountId: String
    public var create: [String: EmailSubmission.Create]?
    public var update: [String: PatchObject]?
    public var destroy: [String]?
    /// Patches for the emails of the submissions that succeeded, keyed by submission id, or by `#` and the
    /// creation id of a submission created in this call.
    public var onSuccessUpdateEmail: [String: PatchObject]?
    public var onSuccessDestroyEmail: [String]?

    public init(
        accountId: String, create: [String: EmailSubmission.Create]? = nil, update: [String: PatchObject]? = nil,
        destroy: [String]? = nil, onSuccessUpdateEmail: [String: PatchObject]? = nil,
        onSuccessDestroyEmail: [String]? = nil
    ) {
        self.accountId = accountId
        self.create = create
        self.update = update
        self.destroy = destroy
        self.onSuccessUpdateEmail = onSuccessUpdateEmail
        self.onSuccessDestroyEmail = onSuccessDestroyEmail
    }
}

public typealias EmailSubmissionGet = GetRequest<EmailSubmission>
public typealias EmailSubmissionQuery = QueryRequest<EmailSubmission>

extension BatchResponse {
    /// The answer to the implicit `Email/set` that `onSuccessUpdateEmail` and `onSuccessDestroyEmail` make. It
    /// follows the `EmailSubmission/set` answer under the same call id (RFC 8621 §7.5).
    ///
    /// Returns `nil` when there is none, as when the submission call failed or had no such arguments; throws
    /// the implicit call's method error.
    public func implicitEmailSet(_ handle: CallHandle<EmailSubmissionSet>) throws -> SetResponse? {
        let answers = invocations.filter { $0.id == handle.id }
        guard answers.first?.name == EmailSubmissionSet.name, let implicit = answers.dropFirst().first else {
            return nil
        }
        switch implicit.name {
        case "error": throw JMAPError.method(try Self.decode(MethodError.self, from: implicit.arguments))
        case EmailSet.name: return try Self.decode(SetResponse.self, from: implicit.arguments)
        default: throw JMAPError.unexpectedResponse(callId: handle.id)
        }
    }
}
