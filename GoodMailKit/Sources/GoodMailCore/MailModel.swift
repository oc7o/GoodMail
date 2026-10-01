import Foundation
import JMAPKit
import Observation

/// State behind the mail screens of one account: mailboxes, the visible thread list, and masked emails.
///
/// Everything is fetched from the server on demand; the offline cache will slot in underneath later.
@MainActor
@Observable
public final class MailModel {
    public enum Destination: Hashable {
        case mailbox(String)
        case maskedEmail
    }

    public enum SearchScope: Hashable {
        case mailbox
        case everywhere
    }

    public struct ThreadQuery: Hashable {
        public var mailboxID: String
        public var search: String
        public var scope: SearchScope
        public var unreadOnly: Bool

        public var searchesEverywhere: Bool { scope == .everywhere && !search.isEmpty }
    }

    public struct MailboxRow: Identifiable {
        public let mailbox: Mailbox
        public let depth: Int
        public var id: String { mailbox.id }
    }

    public static let pageSize = 50

    public let client: JMAPClient
    private let onUnauthorized: () -> Void

    public private(set) var username: String?
    public private(set) var mailboxes: [Mailbox] = []
    public var destination: Destination?

    public var searchText = ""
    public var searchScope = SearchScope.mailbox
    public var showsUnreadOnly = false
    public private(set) var threads: [ThreadSummary] = []
    public private(set) var totalThreads: Int?
    public private(set) var isLoadingThreads = false
    private var isLoadingMore = false
    private var loadedQuery: ThreadQuery?
    public var selectedThreadID: String?

    public private(set) var maskedEmails: [MaskedEmail] = [] {
        didSet {
            maskedEmailsByAddress = Dictionary(
                maskedEmails.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    @ObservationIgnored private var maskedEmailsByAddress: [String: MaskedEmail] = [:]
    public var selectedMaskedEmailID: String?

    public var errorMessage: String?

    public init(client: JMAPClient, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.onUnauthorized = onUnauthorized
    }

    public func start() async {
        username = try? await client.session().username
        await loadMailboxes()
        if destination == nil, let inbox = mailbox(.inbox) ?? mailboxes.first {
            destination = .mailbox(inbox.id)
        }
        await loadMaskedEmails()
    }

    public func refresh() async {
        await loadMailboxes()
        await loadThreads(debounce: false)
    }

    private func report(_ error: Error) {
        if Task.isCancelled { return }
        if case JMAPError.unauthorized = error {
            onUnauthorized()
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Mailboxes

    public func loadMailboxes() async {
        do {
            mailboxes = try await client.mailboxes()
        } catch {
            report(error)
        }
    }

    public func mailbox(_ role: Mailbox.Role) -> Mailbox? {
        mailboxes.first { $0.role == role }
    }

    public func mailbox(id: String) -> Mailbox? {
        mailboxes.first { $0.id == id }
    }

    public var currentMailbox: Mailbox? {
        guard case .mailbox(let id) = destination else { return nil }
        return mailbox(id: id)
    }

    /// Depth-first order: role mailboxes first, then by `sortOrder` and name.
    public var mailboxRows: [MailboxRow] {
        let children = Dictionary(grouping: mailboxes, by: \.parentId)
        func sorted(_ list: [Mailbox]) -> [Mailbox] {
            list.sorted {
                ($0.role == nil ? 1 : 0, $0.sortOrder, $0.name) < ($1.role == nil ? 1 : 0, $1.sortOrder, $1.name)
            }
        }
        func walk(_ parentId: String?, depth: Int) -> [MailboxRow] {
            sorted(children[parentId] ?? []).flatMap { mailbox in
                [MailboxRow(mailbox: mailbox, depth: depth)] + walk(mailbox.id, depth: depth + 1)
            }
        }
        return walk(nil, depth: 0)
    }

    // MARK: Thread list

    public var threadQuery: ThreadQuery? {
        guard case .mailbox(let id) = destination else { return nil }
        return ThreadQuery(
            mailboxID: id, search: searchText.trimmingCharacters(in: .whitespaces),
            scope: searchScope, unreadOnly: showsUnreadOnly)
    }

    public var hasMoreThreads: Bool {
        (totalThreads ?? 0) > threads.count
    }

    public func thread(id: String) -> ThreadSummary? {
        threads.first { $0.id == id }
    }

    public func loadThreads(debounce: Bool = true) async {
        guard let query = threadQuery else { return }
        if query.mailboxID != loadedQuery?.mailboxID {
            threads = []
            totalThreads = nil
            selectedThreadID = nil
            loadedQuery = nil
        }
        if debounce, !query.search.isEmpty, query.search != loadedQuery?.search {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return }

        isLoadingThreads = true
        do {
            let page = try await client.threads(matching: filter(for: query), limit: Self.pageSize)
            guard !Task.isCancelled else { return }
            threads = page.threads
            totalThreads = page.total
            loadedQuery = query
        } catch {
            report(error)
        }
        if !Task.isCancelled { isLoadingThreads = false }
    }

    public func loadMoreThreads() async {
        guard let query = loadedQuery, query == threadQuery, hasMoreThreads, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.threads(
                matching: filter(for: query), position: threads.count, limit: Self.pageSize)
            guard loadedQuery == query else { return }
            let known = Set(threads.map(\.id))
            let fresh = page.threads.filter { !known.contains($0.id) }
            threads += fresh
            if fresh.isEmpty { totalThreads = threads.count }
        } catch {
            report(error)
        }
    }

    private func filter(for query: ThreadQuery) -> Filter<Email.FilterCondition> {
        var conditions: [Filter<Email.FilterCondition>] = []
        if query.searchesEverywhere {
            let hidden = hiddenFromSearchMailboxIDs
            if !hidden.isEmpty { conditions.append(.condition(.init(inMailboxOtherThan: hidden))) }
        } else {
            conditions.append(.condition(.init(inMailbox: query.mailboxID)))
        }
        if !query.search.isEmpty { conditions.append(.condition(.init(text: query.search))) }
        if query.unreadOnly { conditions.append(.condition(.init(notKeyword: Email.Keyword.seen.rawValue))) }
        return conditions.count == 1 ? conditions[0] : .and(conditions)
    }

    private var hiddenFromSearchMailboxIDs: [String] {
        [Mailbox.Role.trash, .junk].compactMap { mailbox($0)?.id }
    }

    private func isListed(_ thread: ThreadSummary, in query: ThreadQuery) -> Bool {
        if query.searchesEverywhere {
            let hidden = Set(hiddenFromSearchMailboxIDs)
            return thread.emails.contains { email in
                !(email.mailboxIds ?? [:]).keys.allSatisfy(hidden.contains)
            }
        }
        return thread.emails.contains { $0.mailboxIds?[query.mailboxID] == true }
    }

    // MARK: Triage

    public func setRead(_ isRead: Bool, threadID: String) async {
        guard let thread = thread(id: threadID) else { return }
        // Marking unread only touches the newest message, like every other mail client.
        let targets = isRead ? thread.emails.filter { !$0.has(.seen) } : [thread.anchor].compactMap { $0 }
        await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .setKeyword(.seen, isRead)) }))
    }

    public func toggleFlag(threadID: String) async {
        guard let thread = thread(id: threadID) else { return }
        let targets = thread.isFlagged ? thread.emails.filter { $0.has(.flagged) } : [thread.anchor].compactMap { $0 }
        await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .setKeyword(.flagged, !thread.isFlagged)) }))
    }

    public var canArchive: Bool {
        guard let archive = mailbox(.archive) else { return false }
        return currentMailbox?.id != archive.id
    }

    public func archive(threadID: String) async {
        guard let archive = mailbox(.archive), let source = currentMailbox ?? mailbox(.inbox) else { return }
        await move(threadID: threadID, from: source.id, to: archive.id)
    }

    public func move(threadID: String, to mailboxID: String) async {
        guard let source = currentMailbox else { return }
        await move(threadID: threadID, from: source.id, to: mailboxID)
    }

    private func move(threadID: String, from source: String, to destination: String) async {
        guard let thread = thread(id: threadID), source != destination else { return }
        let targets = thread.emails.filter { $0.mailboxIds?[source] == true }
        await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .move(from: source, to: destination)) }))
    }

    public var canTrash: Bool {
        guard let trash = mailbox(.trash) else { return false }
        return currentMailbox?.id != trash.id
    }

    public func trash(threadID: String) async {
        guard let thread = thread(id: threadID), let trash = mailbox(.trash) else { return }
        let targets = thread.emails.filter { $0.mailboxIds?[trash.id] != true }
        await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .moveExclusively(to: trash.id)) }))
    }

    /// Updates the list right away, then tells the server; a failure reloads the real state.
    private func apply(_ updates: [String: PatchObject]) async {
        guard !updates.isEmpty else { return }
        for index in threads.indices {
            threads[index].emails = threads[index].emails.map { email in
                updates[email.id].map(email.applying) ?? email
            }
        }
        if let query = loadedQuery {
            let gone = Set(threads.filter { !isListed($0, in: query) }.map(\.id))
            if let selected = selectedThreadID, gone.contains(selected) {
                selectedThreadID = neighbour(of: selected, excluding: gone)
            }
            threads.removeAll { gone.contains($0.id) }
            if let total = totalThreads { totalThreads = max(threads.count, total - gone.count) }
        }

        do {
            try await client.updateEmails(updates)
            await loadMailboxes()
        } catch {
            report(error)
            await refresh()
        }
    }

    private func neighbour(of threadID: String, excluding gone: Set<String>) -> String? {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return nil }
        let after = threads[(index + 1)...].first { !gone.contains($0.id) }
        let before = threads[..<index].last { !gone.contains($0.id) }
        return (after ?? before)?.id
    }

    // MARK: Masked Email

    public func loadMaskedEmails() async {
        do {
            maskedEmails = try await client.maskedEmails()
        } catch {
            report(error)
        }
    }

    /// The masked address this email was delivered to, if any.
    public func maskedEmail(for email: Email) -> MaskedEmail? {
        let recipients = (email.to ?? []) + (email.cc ?? []) + (email.bcc ?? [])
        return recipients.lazy.compactMap { self.maskedEmailsByAddress[$0.email.lowercased()] }.first
    }

    public func createMaskedEmail(_ create: MaskedEmail.Create) async throws -> MaskedEmail {
        let created = try await client.createMaskedEmail(create)
        await loadMaskedEmails()
        return created
    }

    public func setMaskedEmailState(_ state: MaskedEmail.State, id: String) async {
        await updateMaskedEmail(id: id, ["state": .string(state.rawValue)])
    }

    public func setMaskedEmailDescription(_ description: String, id: String) async {
        await updateMaskedEmail(id: id, ["description": .string(description)])
    }

    private func updateMaskedEmail(id: String, _ patch: PatchObject) async {
        do {
            try await client.updateMaskedEmail(id: id, patch)
        } catch {
            report(error)
        }
        await loadMaskedEmails()
    }

    /// Jumps to a search for all mail delivered to `address`.
    public func showMail(to address: String) {
        guard let inbox = mailbox(.inbox) ?? mailboxes.first else { return }
        searchScope = .everywhere
        searchText = address
        destination = .mailbox(inbox.id)
    }
}
