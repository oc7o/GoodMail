import Foundation
import JMAPKit
import MailStore
import Observation

/// State behind the mail screens of one account: mailboxes, the visible thread list, and masked emails.
///
/// Lists are read from the local store, so they appear at once and work offline; the server is asked
/// in parallel and whatever it returns lands in the store first.
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
        /// Whether this is simply everything in the mailbox, which is what coverage is tracked for.
        var isWholeMailbox: Bool { search.isEmpty && !unreadOnly }
    }

    public struct MailboxRow: Identifiable {
        public let mailbox: Mailbox
        public let depth: Int
        public var id: String { mailbox.id }
    }

    public static let pageSize = 50

    public let client: JMAPClient
    private let sync: MailSync
    private var store: MailStore { sync.store }
    private let syncsInBackground: Bool
    private let onUnauthorized: () -> Void

    public private(set) var username: String?
    public private(set) var mailboxes: [Mailbox] = []
    public var destination: Destination?

    public var searchText = ""
    public var searchScope = SearchScope.mailbox
    public var showsUnreadOnly = false
    public private(set) var threads: [ThreadSummary] = []
    public private(set) var hasMoreThreads = false
    public private(set) var isLoadingThreads = false
    public var selectedThreadID: String?

    private var shownQuery: ThreadQuery?
    private var visibleLimit = MailModel.pageSize
    private var serverLoaded = 0
    private var serverTotal: Int?
    /// Threads that stay listed although the stored copy may not match the query (any more): server
    /// search hits, and conversations that would otherwise vanish from a filtered list while being read.
    private var pinnedThreadIDs: [String] = []
    private var isLoadingMore = false
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

    public private(set) var maskedEmails: [MaskedEmail] = [] {
        didSet {
            maskedEmailsByAddress = Dictionary(
                maskedEmails.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    @ObservationIgnored private var maskedEmailsByAddress: [String: MaskedEmail] = [:]
    public var selectedMaskedEmailID: String?

    /// A failed action the user should hear about.
    public var errorMessage: String?
    /// Why the server can't be reached right now, while lists keep showing stored mail.
    public private(set) var connectionProblem: String?

    /// - Parameter syncsInBackground: Keep polling for changes, backfilling older mail and prefetching
    ///   bodies for as long as the model lives.
    public init(
        client: JMAPClient, store: MailStore, syncsInBackground: Bool = true, onUnauthorized: @escaping () -> Void
    ) {
        self.client = client
        self.sync = MailSync(client: client, store: store)
        self.syncsInBackground = syncsInBackground
        self.onUnauthorized = onUnauthorized
    }

    public func start() async {
        mailboxes = (try? await store.mailboxes()) ?? []
        selectInboxIfNeeded()
        username = try? await client.session().username
        await refresh()
        selectInboxIfNeeded()
        await loadMaskedEmails()
        if syncsInBackground { startBackgroundSync() }
    }

    public func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    /// Brings mailboxes and stored mail up to date with the server.
    public func refresh() async {
        await loadMailboxes()
        do {
            let outcome = try await sync.syncChanges()
            connectionProblem = nil
            // Also covers a list that so far only shows stored mail, e.g. after starting offline.
            if outcome == .reset || (serverTotal == nil && !isLoadingThreads) {
                await loadThreads(debounce: false)
                return
            }
        } catch {
            report(error)
        }
        await showStoredThreads()
    }

    private func report(_ error: Error, userInitiated: Bool = false) {
        if Task.isCancelled { return }
        if case JMAPError.unauthorized = error {
            onUnauthorized()
        } else if userInitiated {
            errorMessage = error.localizedDescription
        } else {
            connectionProblem = error.localizedDescription
        }
    }

    // MARK: Background sync

    private func startBackgroundSync() {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            var lastRefresh = ContinuousClock.now
            while !Task.isCancelled {
                guard let hasMoreWork = await self?.performBackgroundWork() else { return }
                try? await Task.sleep(for: hasMoreWork ? .milliseconds(500) : .seconds(20))
                if ContinuousClock.now - lastRefresh >= .seconds(60) {
                    await self?.refresh()
                    lastRefresh = .now
                }
            }
        }
    }

    /// One slice of low-priority work. Returns whether more is waiting.
    private func performBackgroundWork() async -> Bool {
        do {
            if try await sync.backfillNextPage() { return true }
            return try await sync.prefetchBodies() > 0
        } catch {
            return false
        }
    }

    // MARK: Mailboxes

    public func loadMailboxes() async {
        do {
            mailboxes = try await sync.refreshMailboxes()
            connectionProblem = nil
        } catch {
            report(error)
        }
    }

    private func selectInboxIfNeeded() {
        if destination == nil, let inbox = mailbox(.inbox) ?? mailboxes.first {
            destination = .mailbox(inbox.id)
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

    /// Number of conversations in the current list, as far as it is known.
    public var totalThreads: Int? {
        serverTotal ?? (shownQuery?.isWholeMailbox == true ? currentMailbox?.totalThreads : nil)
    }

    public func thread(id: String) -> ThreadSummary? {
        threads.first { $0.id == id }
    }

    /// Shows what is stored for the current query right away, then asks the server for its first page.
    public func loadThreads(debounce: Bool = true) async {
        guard let query = threadQuery else { return }
        let isNewSearch = query.search != shownQuery?.search
        if query.mailboxID != shownQuery?.mailboxID { selectedThreadID = nil }
        if query != shownQuery {
            visibleLimit = Self.pageSize
            serverLoaded = 0
            serverTotal = nil
            pinnedThreadIDs = []
            shownQuery = query
        }
        await showStoredThreads()

        if debounce, !query.search.isEmpty, isNewSearch {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled, shownQuery == query else { return }

        isLoadingThreads = true
        do {
            let page = try await sync.fetchThreads(
                matching: filter(for: query), position: 0, limit: Self.pageSize,
                extendingCoverageOf: query.isWholeMailbox ? query.mailboxID : nil)
            guard !Task.isCancelled, shownQuery == query else { return }
            serverLoaded = page.threads.count
            serverTotal = page.total
            if !query.isWholeMailbox { pin(page.threads.map(\.id)) }
            connectionProblem = nil
            await showStoredThreads()
        } catch {
            report(error)
        }
        if !Task.isCancelled, shownQuery == query { isLoadingThreads = false }
    }

    public func loadMoreThreads() async {
        guard let query = shownQuery, query == threadQuery, hasMoreThreads, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let total = serverTotal, total > serverLoaded {
            do {
                let page = try await sync.fetchThreads(
                    matching: filter(for: query), position: serverLoaded, limit: Self.pageSize,
                    extendingCoverageOf: query.isWholeMailbox ? query.mailboxID : nil)
                guard shownQuery == query else { return }
                serverLoaded += page.threads.count
                serverTotal = page.threads.isEmpty ? serverLoaded : page.total
                if !query.isWholeMailbox { pin(page.threads.map(\.id)) }
            } catch {
                report(error)
            }
        }
        visibleLimit += Self.pageSize
        await showStoredThreads()
    }

    private func pin(_ threadIDs: [String]) {
        let known = Set(pinnedThreadIDs)
        pinnedThreadIDs += threadIDs.filter { !known.contains($0) }
    }

    /// Reads the current list from the store.
    private func showStoredThreads() async {
        guard let query = shownQuery else { return }
        do {
            var listed: [ThreadSummary] = []
            var matchCount = 0
            if let storeQuery = try await storeQuery(for: query) {
                listed = try await store.threads(matching: storeQuery, limit: visibleLimit)
                matchCount = try await store.threadCount(matching: storeQuery)
            }
            let hasMoreStored = matchCount > listed.count

            let known = Set(listed.map(\.id))
            let pinned = try await store.threads(ids: pinnedThreadIDs.filter { !known.contains($0) })
            if !pinned.isEmpty {
                listed = (listed + pinned.filter { isListed($0, in: query) }).sorted {
                    ($0.anchor?.receivedAt ?? .distantPast, $0.id) > ($1.anchor?.receivedAt ?? .distantPast, $1.id)
                }
            }
            guard shownQuery == query else { return }
            if !query.isWholeMailbox { pin(listed.map(\.id)) }
            threads = listed
            hasMoreThreads = hasMoreStored || (serverTotal ?? 0) > serverLoaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The store query matching `query`, or `nil` while nothing stored can answer it yet.
    private func storeQuery(for query: ThreadQuery) async throws -> MailStore.ThreadQuery? {
        if query.searchesEverywhere {
            return .init(hiddenMailboxIDs: hiddenFromSearchMailboxIDs, search: query.search, unreadOnly: query.unreadOnly)
        }
        guard query.isWholeMailbox else {
            return .init(mailboxID: query.mailboxID, search: query.search, unreadOnly: query.unreadOnly)
        }
        // A plain mailbox list must not have gaps, so it only reaches as far back as the copy is complete.
        guard let coverage = try await store.coverage(mailboxID: query.mailboxID) else { return nil }
        return .init(mailboxID: query.mailboxID, since: coverage)
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

    // MARK: Reading

    /// The conversation as stored, if every message's body is available without the network.
    public func storedEmails(inThread threadID: String) async -> [Email]? {
        (try? await store.emailsWithBodies(inThread: threadID)) ?? nil
    }

    /// The conversation from the server, which also refreshes the stored copy.
    public func fetchEmails(inThread threadID: String) async throws -> [Email] {
        let emails = try await sync.fetchThread(threadID)
        await showStoredThreads()
        return emails
    }

    // MARK: Triage

    /// - Parameter userInitiated: Pass `false` when this happens as a side effect, such as opening a
    ///   conversation, so that a failure doesn't interrupt the user.
    public func setRead(_ isRead: Bool, threadID: String, userInitiated: Bool = true) async {
        guard let thread = thread(id: threadID) else { return }
        // Marking unread only touches the newest message, like every other mail client.
        let targets = isRead ? thread.emails.filter { !$0.has(.seen) } : [thread.anchor].compactMap { $0 }
        await apply(
            Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .setKeyword(.seen, isRead)) }),
            userInitiated: userInitiated)
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

    /// Changes the stored emails and the list right away, then tells the server; if it refuses, the
    /// stored emails are put back.
    private func apply(_ updates: [String: PatchObject], userInitiated: Bool = true) async {
        guard !updates.isEmpty else { return }
        let listedBefore = threads.map(\.id)
        do {
            let originals = try await sync.stage(updates)
            await showStoredThreads()
            let removed = Set(listedBefore).subtracting(threads.map(\.id))
            if let selected = selectedThreadID, removed.contains(selected) {
                selectedThreadID = neighbour(of: selected, in: listedBefore, excluding: removed)
            }
            let serverCounts = (serverLoaded, serverTotal)
            serverLoaded = max(0, serverLoaded - removed.count)
            serverTotal = serverTotal.map { max(0, $0 - removed.count) }

            do {
                try await sync.commit(updates, reverting: originals)
            } catch {
                (serverLoaded, serverTotal) = serverCounts
                report(error, userInitiated: userInitiated)
                await showStoredThreads()
                return
            }
            _ = try? await sync.syncChanges()
            await loadMailboxes()
            await showStoredThreads()
        } catch {
            report(error, userInitiated: userInitiated)
        }
    }

    private func neighbour(of threadID: String, in order: [String], excluding removed: Set<String>) -> String? {
        guard let index = order.firstIndex(of: threadID) else { return nil }
        let after = order[(index + 1)...].first { !removed.contains($0) }
        let before = order[..<index].last { !removed.contains($0) }
        return after ?? before
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
            report(error, userInitiated: true)
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
