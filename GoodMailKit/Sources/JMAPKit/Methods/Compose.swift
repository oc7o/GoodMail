import Foundation

/// The ids of the mailboxes sending moves mail between.
public struct MailboxRoles: Sendable, Equatable {
    public var drafts: String
    public var sent: String

    public init(drafts: String, sent: String) {
        self.drafts = drafts
        self.sent = sent
    }
}

/// What saving a draft did. The server creates the new version and destroys the previous one independently,
/// so either may happen without the other.
public struct DraftSaveResult: Sendable, Equatable {
    public var createdID: String?
    public var createError: SetError?
    /// The previous version is gone now: destroyed, or already missing.
    public var destroyedPrevious: Bool
    /// The previous version was already gone, changed or deleted elsewhere.
    public var previousWasMissing: Bool

    public init(createdID: String?, createError: SetError?, destroyedPrevious: Bool, previousWasMissing: Bool) {
        self.createdID = createdID
        self.createError = createError
        self.destroyedPrevious = destroyedPrevious
        self.previousWasMissing = previousWasMissing
    }
}

/// What sending did. Failures of either call are reported here rather than thrown, because the email may have
/// been created although its submission failed, and must then be cleaned up.
public struct SubmissionResult: Sendable, Equatable {
    /// The email created to be sent, whatever happened to its submission.
    public var emailID: String?
    public var emailError: SetError?
    /// The submission with the server's `id`, `undoStatus` and `sendAt`.
    public var submission: EmailSubmission?
    public var submissionError: SetError?
    /// `EmailSubmission/set` failed as a whole, after the email was created.
    public var submissionMethodError: MethodError?
    /// The email was moved to Sent and is no draft any more.
    public var movedToSent: Bool

    public init(
        emailID: String? = nil, emailError: SetError? = nil, submission: EmailSubmission? = nil,
        submissionError: SetError? = nil, submissionMethodError: MethodError? = nil, movedToSent: Bool = false
    ) {
        self.emailID = emailID
        self.emailError = emailError
        self.submission = submission
        self.submissionError = submissionError
        self.submissionMethodError = submissionMethodError
        self.movedToSent = movedToSent
    }
}

public enum SubmissionCancellation: Sendable, Equatable {
    /// The message won't be sent, and its email is back in Drafts.
    case canceled
    /// Too late: the submission was released already.
    case alreadySent
    case failed(SetError)
}

/// The properties of an email needed to tell copies of one message apart.
public struct EmailCopy: Sendable, Equatable {
    public let id: String
    public let mailboxIds: [String: Bool]
    public let keywords: [String: Bool]
    public let messageId: [String]
    public let receivedAt: Date?

    public init(
        id: String, mailboxIds: [String: Bool], keywords: [String: Bool], messageId: [String], receivedAt: Date?
    ) {
        self.id = id
        self.mailboxIds = mailboxIds
        self.keywords = keywords
        self.messageId = messageId
        self.receivedAt = receivedAt
    }

    init(_ email: Email) {
        self.init(
            id: email.id, mailboxIds: email.mailboxIds ?? [:], keywords: email.keywords ?? [:],
            messageId: email.messageId ?? [], receivedAt: email.receivedAt)
    }

    public var isDraft: Bool {
        keywords[Email.Keyword.draft.rawValue] == true
    }

    static let properties = ["id", "mailboxIds", "keywords", "messageId", "receivedAt"]
}

public struct MessageIDLookup: Sendable, Equatable {
    /// The emails with the Message-ID, checked here rather than trusting the server's filter.
    public var matches: [EmailCopy]
    /// Whether the server applied the header filter. When it didn't, `matches` may miss copies, and recent
    /// mail has to be searched instead (`recentEmails(inMailboxes:after:limit:)`).
    public var filterWorked: Bool

    public init(matches: [EmailCopy], filterWorked: Bool) {
        self.matches = matches
        self.filterWorked = filterWorked
    }
}

/// The header fields that decide how to unsubscribe from a list (RFC 2369, RFC 8058), each field in the order of
/// the message, topmost first.
public struct UnsubscribeHeaders: Sendable, Equatable {
    /// The URLs of each `List-Unsubscribe` field; empty for a field that couldn't be parsed.
    public var listUnsubscribe: [[String]]
    public var listUnsubscribePost: [String]
    /// Raw, so that the tags can be parsed as signed.
    public var dkimSignatures: [String]
    public var authenticationResults: [String]
    public var listId: String?

    public init(
        listUnsubscribe: [[String]], listUnsubscribePost: [String], dkimSignatures: [String],
        authenticationResults: [String], listId: String?
    ) {
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.dkimSignatures = dkimSignatures
        self.authenticationResults = authenticationResults
        self.listId = listId
    }
}

extension JMAPClient {
    public func identities() async throws -> [Identity] {
        let accountId = try await accountId(for: Capability.submission)
        return try await call(IdentityGet(accountId: accountId)).list
    }

    /// Creates an identity to send from `create.email`. Throws the server's `SetError` when it refuses, such as
    /// `forbiddenFrom` for an address the account may not send from.
    ///
    /// The request is never repeated automatically, as a repeat would make a second identity. After an error
    /// whose `mayHaveReachedServer` is true, the identity may exist.
    public func createIdentity(_ create: Identity.Create) async throws -> Identity {
        let accountId = try await session(for: .never).primaryAccountId(for: Capability.submission)
        let response = try await call(IdentitySet(accountId: accountId, create: ["i": create]), retry: .never)
        if let error = response.notCreated?["i"] { throw error }
        guard let created = try response.created("i", as: CreatedIdentity.self) else {
            throw JMAPError.unexpectedResponse(callId: "i")
        }
        return Identity(
            id: created.id, name: created.name ?? create.name, email: created.email ?? create.email,
            replyTo: created.replyTo, bcc: created.bcc, textSignature: created.textSignature,
            htmlSignature: created.htmlSignature, mayDelete: created.mayDelete ?? true)
    }

    /// Saves a new version of a draft and destroys the previous one in the same request (RFC 8621 §4.10).
    public func saveDraft(_ email: EmailCreate, replacing previousID: String?) async throws -> DraftSaveResult {
        let accountId = try await accountId(for: Capability.mail)
        let response = try await call(EmailSet(
            accountId: accountId, create: ["d": email], destroy: previousID.map { [$0] }))
        let previousWasMissing = previousID.flatMap { response.notDestroyed?[$0] }?.type == SetError.notFound
        let destroyed = previousID.map { response.destroyed?.contains($0) == true } ?? false
        return DraftSaveResult(
            createdID: try response.created("d", as: CreatedEmail.self)?.id, createError: response.notCreated?["d"],
            destroyedPrevious: destroyed || previousWasMissing, previousWasMissing: previousWasMissing)
    }

    /// Creates the final email and submits it in one request, moving it to Sent once the submission exists.
    ///
    /// The request is never repeated automatically, and destroys nothing: the previous draft is only removed
    /// after the outcome is known (`destroyEmails(_:)`). An error thrown means it is unknown whether the server
    /// acted on it, unless the error's `mayHaveReachedServer` is false.
    public func submit(
        _ email: EmailCreate, identityID: String, envelope: EmailSubmission.Envelope, mailboxes: MailboxRoles
    ) async throws -> SubmissionResult {
        let session = try await session(for: .never)
        let mailAccountId = try session.primaryAccountId(for: Capability.mail)
        let submissionAccountId = try session.primaryAccountId(for: Capability.submission)
        var batch = Batch()
        let creation = batch.add(EmailSet(accountId: mailAccountId, create: ["m": email]))
        let submission = batch.add(EmailSubmissionSet(
            accountId: submissionAccountId,
            create: ["s": .init(identityId: identityID, emailId: "#m", envelope: envelope)],
            onSuccessUpdateEmail: ["#s": PatchObject.move(from: mailboxes.drafts, to: mailboxes.sent)
                .merging(.setKeyword(.draft, false))]))
        let response = try await send(batch, retry: .never)

        let created = try response.get(creation)
        let createdEmail = try created.created("m", as: CreatedEmail.self)
        var result = SubmissionResult(emailID: createdEmail?.id, emailError: created.notCreated?["m"])
        let submitted: SetResponse
        do {
            submitted = try response.get(submission)
        } catch JMAPError.method(let error) {
            result.submissionMethodError = error
            return result
        }
        result.submissionError = submitted.notCreated?["s"]
        if let server = try submitted.created("s", as: CreatedSubmission.self) {
            result.submission = EmailSubmission(
                id: server.id, identityId: identityID, emailId: createdEmail?.id,
                threadId: server.threadId ?? createdEmail?.threadId, envelope: envelope, sendAt: server.sendAt,
                undoStatus: server.undoStatus)
        }
        if let emailID = createdEmail?.id, let implicit = try? response.implicitEmailSet(submission) {
            result.movedToSent = implicit.updated?.keys.contains(emailID) == true
        }
        return result
    }

    /// Destroys emails, such as earlier versions of a sent draft, and returns the ones the server refused.
    /// An email that is gone already counts as destroyed.
    @discardableResult
    public func destroyEmails(_ ids: [String]) async throws -> [String: SetError] {
        guard !ids.isEmpty else { return [:] }
        let accountId = try await accountId(for: Capability.mail)
        let response = try await call(EmailSet(accountId: accountId, destroy: ids))
        return (response.notDestroyed ?? [:]).filter { $0.value.type != SetError.notFound }
    }

    /// Cancels a held submission (Undo Send) and moves its email back to Drafts.
    ///
    /// The request is never repeated automatically: a cancelled submission is deleted, so a repeat would find
    /// it gone and report `alreadySent` for a message that is back in Drafts. After an error whose
    /// `mayHaveReachedServer` is true, the submission may have been cancelled.
    public func cancelSubmission(_ id: String, mailboxes: MailboxRoles) async throws -> SubmissionCancellation {
        let accountId = try await session(for: .never).primaryAccountId(for: Capability.submission)
        let response = try await call(EmailSubmissionSet(
            accountId: accountId, update: [id: ["undoStatus": .string(EmailSubmission.UndoStatus.canceled.rawValue)]],
            onSuccessUpdateEmail: [id: PatchObject.move(from: mailboxes.sent, to: mailboxes.drafts)
                .merging(.setKeyword(.draft, true))]), retry: .never)
        if response.updated?.keys.contains(id) == true { return .canceled }
        guard let error = response.notUpdated?[id] else { throw JMAPError.unexpectedResponse(callId: id) }
        // Fastmail deletes a submission once it is released, so a late cancel finds nothing.
        return [SetError.notFound, SetError.cannotUnsend].contains(error.type) ? .alreadySent : .failed(error)
    }

    public func submissions(ids: [String]) async throws -> (found: [EmailSubmission], notFound: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        let accountId = try await accountId(for: Capability.submission)
        let response = try await call(EmailSubmissionGet(accountId: accountId, ids: .ids(ids)))
        return (response.list, response.notFound)
    }

    /// The submissions still on the server for any of the emails, which on Fastmail means the held ones.
    public func submissions(forEmailIDs ids: [String]) async throws -> [EmailSubmission] {
        guard !ids.isEmpty else { return [] }
        let accountId = try await accountId(for: Capability.submission)
        var batch = Batch()
        let query = batch.add(EmailSubmissionQuery(accountId: accountId, filter: .condition(.init(emailIds: ids))))
        let get = batch.add(EmailSubmissionGet(
            accountId: accountId, ids: .reference(query.reference("/ids")),
            properties: ["id", "emailId", "undoStatus", "sendAt"]))
        return try await send(batch).get(get).list
    }

    /// The emails with a Message-ID, found with the `header` filter (RFC 8621 §4.4.1).
    public func emails(withMessageID messageID: String) async throws -> MessageIDLookup {
        let accountId = try await accountId(for: Capability.mail)
        var batch = Batch()
        let query = batch.add(EmailQuery(
            accountId: accountId, filter: .condition(.init(header: ["Message-ID", messageID])), limit: 50))
        let get = batch.add(EmailGet(
            accountId: accountId, ids: .reference(query.reference("/ids")), properties: EmailCopy.properties))
        let found = try await send(batch).get(get).list.map(EmailCopy.init)
        let matches = found.filter { $0.messageId.contains(messageID) }
        return MessageIDLookup(matches: matches, filterWorked: matches.count == found.count)
    }

    /// The newest emails received at or after `date` in any of the mailboxes, newest first.
    public func recentEmails(inMailboxes ids: [String], after date: Date, limit: Int) async throws -> [EmailCopy] {
        guard !ids.isEmpty else { return [] }
        let accountId = try await accountId(for: Capability.mail)
        var batch = Batch()
        let query = batch.add(EmailQuery(
            accountId: accountId,
            filter: .and([.or(ids.map { .condition(.init(inMailbox: $0)) }), .condition(.init(after: date))]),
            sort: [Comparator(property: "receivedAt", isAscending: false)], limit: limit))
        let get = batch.add(EmailGet(
            accountId: accountId, ids: .reference(query.reference("/ids")), properties: EmailCopy.properties))
        let response = try await send(batch)
        let emailsById = Dictionary(
            try response.get(get).list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try response.get(query).ids.compactMap { emailsById[$0] }.map(EmailCopy.init)
    }

    /// Emails with just the given properties.
    public func emails(ids: [String], properties: [String]) async throws -> [Email] {
        guard !ids.isEmpty else { return [] }
        let accountId = try await accountId(for: Capability.mail)
        return try await call(EmailGet(accountId: accountId, ids: .ids(ids), properties: properties)).list
    }

    /// The list headers of an email, or `nil` if it doesn't exist.
    public func unsubscribeHeaders(emailID: String) async throws -> UnsubscribeHeaders? {
        let accountId = try await accountId(for: Capability.mail)
        let response = try await call(GetRequest<ListHeaders>(
            accountId: accountId, ids: [emailID], properties: ListHeaders.properties))
        guard let email = response.list.first(where: { $0.id == emailID }) else { return nil }
        return UnsubscribeHeaders(
            listUnsubscribe: (email.listUnsubscribe ?? []).map { $0 ?? [] },
            listUnsubscribePost: email.listUnsubscribePost ?? [], dkimSignatures: email.dkimSignatures ?? [],
            authenticationResults: email.authenticationResults ?? [], listId: email.listId)
    }
}

/// The server-set properties of a created email (RFC 8621 §4.6).
private struct CreatedEmail: Decodable {
    let id: String
    let threadId: String?
}

private struct CreatedSubmission: Decodable {
    let id: String
    let threadId: String?
    let undoStatus: EmailSubmission.UndoStatus?
    let sendAt: Date?
}

/// What the server returns for a created identity: at least its `id`, maybe more.
private struct CreatedIdentity: Decodable {
    let id: String
    let name: String?
    let email: String?
    let replyTo: [EmailAddress]?
    let bcc: [EmailAddress]?
    let textSignature: String?
    let htmlSignature: String?
    let mayDelete: Bool?
}

/// An email's list headers, in the forms `UnsubscribeHeaders` holds.
private struct ListHeaders: JMAPObject {
    static let typeName = Email.typeName
    static let capability = Email.capability

    let id: String
    let listUnsubscribe: [[String]?]?
    let listUnsubscribePost: [String]?
    let dkimSignatures: [String]?
    let authenticationResults: [String]?
    let listId: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case listUnsubscribe = "header:List-Unsubscribe:asURLs:all"
        case listUnsubscribePost = "header:List-Unsubscribe-Post:asText:all"
        case dkimSignatures = "header:DKIM-Signature:all"
        case authenticationResults = "header:Authentication-Results:asText:all"
        case listId = "header:List-Id:asText"
    }

    static let properties = CodingKeys.allCases.map(\.rawValue)
}
