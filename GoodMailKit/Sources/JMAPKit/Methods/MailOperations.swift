import Foundation

/// A conversation as shown in a message list.
public struct ThreadSummary: Identifiable, Sendable, Equatable {
    public let id: String
    /// Every email of the thread across all mailboxes, oldest first.
    public var emails: [Email]
    /// The email that put the thread in the list: the newest one matching the query.
    public let anchorId: String

    public init(id: String, emails: [Email], anchorId: String) {
        self.id = id
        self.emails = emails
        self.anchorId = anchorId
    }

    public var anchor: Email? { emails.first { $0.id == anchorId } ?? emails.last }
    public var isUnread: Bool { emails.contains { !$0.has(.seen) } }
    public var isFlagged: Bool { emails.contains { $0.has(.flagged) } }
    public var hasAttachment: Bool { emails.contains { $0.hasAttachment == true } }
}

public struct ThreadPage: Sendable, Equatable {
    public let threads: [ThreadSummary]
    public let position: Int
    /// Number of threads matching the query, if the server calculated it.
    public let total: Int?
}

extension JMAPClient {
    public func mailboxes() async throws -> [Mailbox] {
        let accountId = try await accountId(for: Capability.mail)
        return try await call(MailboxGet(accountId: accountId)).list
    }

    /// One page of conversations matching `filter`, newest first, in a single round trip.
    public func threads(
        matching filter: Filter<Email.FilterCondition>?, position: Int = 0, limit: Int = 50
    ) async throws -> ThreadPage {
        let accountId = try await accountId(for: Capability.mail)
        var batch = Batch()
        let query = batch.add(EmailQuery(
            accountId: accountId, filter: filter,
            sort: [Comparator(property: "receivedAt", isAscending: false)],
            position: position, limit: limit, calculateTotal: true, collapseThreads: true))
        let anchors = batch.add(EmailGet(
            accountId: accountId, ids: .reference(query.reference("/ids")), properties: ["threadId"]))
        let threads = batch.add(ThreadGet(
            accountId: accountId, ids: .reference(anchors.reference("/list/*/threadId"))))
        let emails = batch.add(EmailGet(
            accountId: accountId, ids: .reference(threads.reference("/list/*/emailIds"))))
        let response = try await send(batch)

        let queryResult = try response.get(query)
        let threadIdByAnchor = Dictionary(
            try response.get(anchors).list.compactMap { email in email.threadId.map { (email.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let threadsById = Dictionary(
            try response.get(threads).list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let emailsById = Dictionary(
            try response.get(emails).list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let summaries = queryResult.ids.compactMap { anchorId -> ThreadSummary? in
            guard let threadId = threadIdByAnchor[anchorId], let thread = threadsById[threadId] else { return nil }
            return ThreadSummary(
                id: threadId, emails: thread.emailIds.compactMap { emailsById[$0] }, anchorId: anchorId)
        }
        return ThreadPage(threads: summaries, position: queryResult.position, total: queryResult.total)
    }

    /// Every email of a thread with its displayable body, oldest first.
    public func emails(inThread threadId: String, maxBodyValueBytes: Int = 1_000_000) async throws -> [Email] {
        let accountId = try await accountId(for: Capability.mail)
        var batch = Batch()
        let thread = batch.add(ThreadGet(accountId: accountId, ids: [threadId]))
        let emails = batch.add(EmailGet(
            accountId: accountId, ids: .reference(thread.reference("/list/*/emailIds")),
            properties: Email.Properties.full, fetchHTMLBodyValues: true, maxBodyValueBytes: maxBodyValueBytes))
        let response = try await send(batch)

        let order = try response.get(thread).list.first?.emailIds ?? []
        let emailsById = Dictionary(
            try response.get(emails).list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { emailsById[$0] }
    }

    /// Applies one patch per email id. Throws the first `SetError` if the server rejects any of them.
    public func updateEmails(_ updates: [String: PatchObject]) async throws {
        guard !updates.isEmpty else { return }
        let accountId = try await accountId(for: Capability.mail)
        let response = try await call(EmailSet(accountId: accountId, update: updates))
        if let error = response.notUpdated?.min(by: { $0.key < $1.key })?.value { throw error }
    }
}
