import Foundation
import JMAPKit

/// What is known about the account, kept in the store so that composing and sending work from a cold start
/// without a connection (D34): who the user is, what the token may do, the server's limits and the identities.
public struct AccountSnapshot: Codable, Sendable, Equatable {
    public var username: String
    public var mailAccountID: String
    public var submissionAccountID: String?
    /// The session offers submission for an account that isn't read-only (`Session.canSubmit`).
    public var canSubmit: Bool
    public var isReadOnly: Bool
    public var maxSizeAttachmentsPerEmail: Int?
    public var maxSizeRequest: Int?
    public var maxSizeUpload: Int?
    public var maxDelayedSend: Int?
    public var identities: [Identity]
    /// Identities Fastmail keeps out of its own From menu (`showInCompose` false); GoodMail does the same.
    public var hiddenIdentityIDs: [String]
    /// Fastmail refused to hold a submission (C23), so sending waits out the Undo window on this device instead.
    public var serverHoldUnsupported: Bool
    public var updatedAt: Date

    public init(
        username: String, mailAccountID: String, submissionAccountID: String? = nil, canSubmit: Bool,
        isReadOnly: Bool = false, maxSizeAttachmentsPerEmail: Int? = nil, maxSizeRequest: Int? = nil,
        maxSizeUpload: Int? = nil, maxDelayedSend: Int? = nil, identities: [Identity] = [],
        hiddenIdentityIDs: [String] = [], serverHoldUnsupported: Bool = false, updatedAt: Date
    ) {
        self.username = username
        self.mailAccountID = mailAccountID
        self.submissionAccountID = submissionAccountID
        self.canSubmit = canSubmit
        self.isReadOnly = isReadOnly
        self.maxSizeAttachmentsPerEmail = maxSizeAttachmentsPerEmail
        self.maxSizeRequest = maxSizeRequest
        self.maxSizeUpload = maxSizeUpload
        self.maxDelayedSend = maxDelayedSend
        self.identities = identities
        self.hiddenIdentityIDs = hiddenIdentityIDs
        self.serverHoldUnsupported = serverHoldUnsupported
        self.updatedAt = updatedAt
    }

    /// The `keyedData` key it is stored under.
    static let storeKey = "account"

    /// The snapshot the session describes, keeping what only the server's answers taught (identities, a refused
    /// hold) from `previous` when it is the same account.
    init?(session: Session, previous: AccountSnapshot?, at date: Date) {
        guard let mailAccountID = session.primaryAccounts[Capability.mail] else { return nil }
        let submissionAccountID = session.supports(Capability.submission)
            ? session.primaryAccounts[Capability.submission] : nil
        let sameAccount = previous?.mailAccountID == mailAccountID
        let accountID = submissionAccountID ?? mailAccountID
        self.init(
            username: session.username, mailAccountID: mailAccountID, submissionAccountID: submissionAccountID,
            canSubmit: session.canSubmit, isReadOnly: session.accounts[accountID]?.isReadOnly ?? false,
            maxSizeAttachmentsPerEmail: session.mailCapabilities(accountId: mailAccountID)?.maxSizeAttachmentsPerEmail,
            maxSizeRequest: session.coreCapabilities?.maxSizeRequest,
            maxSizeUpload: session.coreCapabilities?.maxSizeUpload,
            maxDelayedSend: submissionAccountID.flatMap { session.submissionCapabilities(accountId: $0)?.maxDelayedSend },
            identities: session.canSubmit && sameAccount ? previous?.identities ?? [] : [],
            hiddenIdentityIDs: session.canSubmit && sameAccount ? previous?.hiddenIdentityIDs ?? [] : [],
            serverHoldUnsupported: sameAccount && previous?.serverHoldUnsupported == true, updatedAt: date)
    }

    public var sendAvailability: SendAvailability {
        if canSubmit { return .available }
        return submissionAccountID != nil && isReadOnly ? .readOnlyAccount : .tokenLacksSubmission
    }

    /// Whether Fastmail holds submissions for the Undo window (D12); otherwise this device waits it out.
    var holdsOnServer: Bool {
        (maxDelayedSend ?? 0) >= Outbox.holdSeconds && !serverHoldUnsupported
    }

    // Fields added later decode with their defaults, so a snapshot from an older version still loads.
    private enum CodingKeys: String, CodingKey {
        case username, mailAccountID, submissionAccountID, canSubmit, isReadOnly, maxSizeAttachmentsPerEmail
        case maxSizeRequest, maxSizeUpload, maxDelayedSend, identities, hiddenIdentityIDs, serverHoldUnsupported
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        mailAccountID = try container.decode(String.self, forKey: .mailAccountID)
        submissionAccountID = try container.decodeIfPresent(String.self, forKey: .submissionAccountID)
        canSubmit = try container.decodeIfPresent(Bool.self, forKey: .canSubmit) ?? false
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        maxSizeAttachmentsPerEmail = try container.decodeIfPresent(Int.self, forKey: .maxSizeAttachmentsPerEmail)
        maxSizeRequest = try container.decodeIfPresent(Int.self, forKey: .maxSizeRequest)
        maxSizeUpload = try container.decodeIfPresent(Int.self, forKey: .maxSizeUpload)
        maxDelayedSend = try container.decodeIfPresent(Int.self, forKey: .maxDelayedSend)
        identities = try container.decodeIfPresent([Identity].self, forKey: .identities) ?? []
        hiddenIdentityIDs = try container.decodeIfPresent([String].self, forKey: .hiddenIdentityIDs) ?? []
        serverHoldUnsupported = try container.decodeIfPresent(Bool.self, forKey: .serverHoldUnsupported) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// Whether mail can be sent with the current token.
public enum SendAvailability: Sendable, Equatable {
    case available
    /// Nothing is known about the account yet (first start without a connection); messages can still be queued.
    case unknown
    /// The token lacks the "Email submission" scope: drafts save, sending needs a new token (D18).
    case tokenLacksSubmission
    case readOnlyAccount
}

/// An identity as Fastmail lists it, with its `showInCompose` flag, which `Identity` leaves out.
struct ListedIdentity: JMAPObject {
    static let typeName = Identity.typeName
    static let capability = Identity.capability

    let identity: Identity
    let showInCompose: Bool

    var id: String { identity.id }

    private enum CodingKeys: String, CodingKey { case showInCompose }

    init(from decoder: any Decoder) throws {
        identity = try Identity(from: decoder)
        showInCompose = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .showInCompose) ?? true
    }
}

extension JMAPClient {
    /// The identities with the ones Fastmail hides from compose.
    func listedIdentities() async throws -> [ListedIdentity] {
        let accountId = try await accountId(for: Capability.submission)
        return try await call(GetRequest<ListedIdentity>(accountId: accountId)).list
    }
}
