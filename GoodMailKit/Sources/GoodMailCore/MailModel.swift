import Foundation
import JMAPKit
import MailCompose
import MailStore
import Observation

/// State behind the mail screens of one account: mailboxes, the visible thread list, masked emails, and the
/// outbox with the composers writing into it.
///
/// Lists are read from the local store, so they appear at once and work offline; the server is asked
/// in parallel and whatever it returns lands in the store first.
@MainActor
@Observable
public final class MailModel {
    public enum Destination: Hashable {
        case mailbox(String)
        case savedSearch(String)
        case maskedEmail
        case outbox

        var isSavedSearch: Bool {
            if case .savedSearch = self { true } else { false }
        }
    }

    public enum SearchScope: Hashable {
        case mailbox
        case everywhere
    }

    public struct ThreadQuery: Hashable {
        var destination: Destination
        /// The mailbox listed or searched; `nil` for all mail but Trash and Spam.
        public var mailboxID: String?
        public var search: SearchQuery
        public var unreadOnly: Bool
        /// The mailbox it names doesn't exist.
        var matchesNothing = false

        /// Whether this is simply everything in the mailbox, which is what coverage is tracked for.
        var isWholeMailbox: Bool { mailboxID != nil && !search.hasCriteria && !unreadOnly }
    }

    public struct MailboxRow: Identifiable {
        public let mailbox: Mailbox
        public let depth: Int
        public var id: String { mailbox.id }
    }

    public static let pageSize = 50
    /// The pushed types a refresh catches up on; Masked Email is pushed and reloaded separately.
    private static let pushedMailTypes = ["Email", "Mailbox", "Thread", "EmailDelivery"]

    public let client: JMAPClient
    private let sync: MailSync
    var store: MailStore { sync.store }
    private let syncsInBackground: Bool
    private let onUnauthorized: () -> Void
    let clock: any OutboxClock
    private let network: any NetworkPathSource
    let backgroundActivity: any BackgroundActivity

    /// Messages being sent and drafts written on this device.
    public let outbox: Outbox
    /// What is known about the account, kept for starting offline (D34).
    public private(set) var account: AccountSnapshot? {
        didSet { sendAvailability = account?.sendAvailability ?? .unknown }
    }
    public private(set) var sendAvailability = SendAvailability.unknown
    /// Whether the device has a network connection, as far as the system can tell.
    public private(set) var isOnline = true
    /// The composers open in windows and sheets, by draft id.
    @ObservationIgnored var openComposers: [UUID: Composer] = [:]
    /// When the last successful sync of stored mail started; the outbox's server-copy check needs it (§2.3).
    @ObservationIgnored private(set) var lastSyncStartedAt: Date?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private(set) var networkPath: NetworkPath?

    public private(set) var username: String?
    public private(set) var mailboxes: [Mailbox] = []
    public private(set) var savedSearches: [SavedSearch] = []
    public var destination: Destination? {
        didSet {
            // Text typed into a saved search refines it, so it means nothing anywhere else.
            if destination != oldValue, destination?.isSavedSearch == true || oldValue?.isSavedSearch == true {
                searchText = ""
            }
        }
    }

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
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// The wait before push reconnects after a failure; cancelling it reconnects at once.
    @ObservationIgnored private var pushRetry: Task<Void, Never>?
    /// How long push waits before reconnecting after `failures` failed attempts in a row.
    @ObservationIgnored var pushRetryDelay: (_ failures: Int) -> Duration = { failures in
        .seconds(min(1 << min(failures, 6), 60)) * Double.random(in: 0.9...1.1)
    }
    /// How long a connection must last for the backoff to start over once it ends.
    @ObservationIgnored var stablePushConnection: Duration = .seconds(60)
    /// How often `stop()` was called, so that a `start()` under way can tell it was stopped meanwhile.
    @ObservationIgnored private var stops = 0
    private let refreshes = SingleFlight()
    private let flushes = SingleFlight()
    private let maskedEmailLoads = SingleFlight()
    private let identityLoads = SingleFlight()

    public private(set) var maskedEmails: [MaskedEmail] = [] {
        didSet {
            maskedEmailsByAddress = Dictionary(
                maskedEmails.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    @ObservationIgnored private(set) var maskedEmailsByAddress: [String: MaskedEmail] = [:]
    public var selectedMaskedEmailID: String?

    /// A failed action the user should hear about.
    public var errorMessage: String?
    /// Why the server can't be reached right now, while lists keep showing stored mail.
    public private(set) var connectionProblem: String?
    /// Emails with changes the server hasn't received yet.
    public private(set) var pendingChangeCount = 0
    /// Whether the server pushes its changes as they happen, so that polling can slow down.
    public private(set) var isPushConnected = false

    /// - Parameters:
    ///   - syncsInBackground: Until `stop()`, take in changes as the server pushes them (polling as a fallback),
    ///     backfill older mail and prefetch bodies.
    ///   - clock: The time every outbox and autosave deadline goes by.
    ///   - network: The network path; mail waiting to be sent goes out as soon as it is back.
    ///   - backgroundActivity: Keeps the app running while mail is sent (iOS: `beginBackgroundTask`).
    public init(
        client: JMAPClient, store: MailStore, syncsInBackground: Bool = true,
        clock: any OutboxClock = SystemOutboxClock(), network: any NetworkPathSource = SystemNetworkPath(),
        backgroundActivity: any BackgroundActivity = NoBackgroundActivity(), onUnauthorized: @escaping () -> Void
    ) {
        self.client = client
        self.sync = MailSync(client: client, store: store)
        self.syncsInBackground = syncsInBackground
        self.onUnauthorized = onUnauthorized
        self.clock = clock
        self.network = network
        self.backgroundActivity = backgroundActivity
        outbox = Outbox(client: client, store: store, clock: clock, activity: backgroundActivity)
        outbox.host = self
    }

    public func start() async {
        let stops = self.stops
        // stop() cancels what it finds under way, but this mustn't go on to start more.
        var isStopped: Bool { self.stops != stops }
        await loadStoredAccount()
        mailboxes = (try? await store.mailboxes()) ?? []
        savedSearches = (try? await store.savedSearches()) ?? []
        maskedEmails = (try? await store.maskedEmails()) ?? []
        selectInboxIfNeeded()
        await updatePendingChangeCount()
        await outbox.start()
        startWatchingNetwork()
        await refreshAccount()
        guard !isStopped else { return }
        await refresh()
        selectInboxIfNeeded()
        guard !isStopped else { return }
        await loadMaskedEmails()
        guard syncsInBackground, !isStopped else { return }
        startBackgroundSync()
        startPush()
    }

    /// Ends background syncing, push and the outbox's timers and uploads, and cancels refreshes and loads
    /// under way. What was cut short is picked up from the persisted states on the next start.
    public func stop() {
        stops += 1
        backgroundTask?.cancel()
        backgroundTask = nil
        stopPush()
        refreshes.cancel()
        maskedEmailLoads.cancel()
        identityLoads.cancel()
        networkTask?.cancel()
        networkTask = nil
        outbox.stop()
    }

    /// Sends queued changes, then brings mailboxes and stored mail up to date with the server.
    ///
    /// Only one refresh runs at a time; callers arriving meanwhile wait for it, and it then makes one more
    /// pass so that a change announced after its look at the server isn't missed.
    public func refresh() async {
        await requestRefresh().value
    }

    @discardableResult
    private func requestRefresh() -> Task<Void, Never> {
        refreshes.start { await self.refreshOnce() }
    }

    private func refreshOnce() async {
        await flushPendingChanges()
        // Not awaited: uploads can take minutes and must never hold up mail sync.
        if !Task.isCancelled { outbox.requestFlush() }
        await loadMailboxes()
        do {
            let started = clock.now
            let hasState = (try? await store.emailState()) != nil
            let outcome = try await sync.syncChanges()
            if hasState { lastSyncStartedAt = started }
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
                // While changes are pushed, polling only backs up a connection that died unnoticed.
                let interval: Duration = self?.isPushConnected == true ? .seconds(300) : .seconds(60)
                if ContinuousClock.now - lastRefresh >= interval {
                    await self?.refresh()
                    lastRefresh = .now
                }
            }
        }
    }

    /// One slice of low-priority work. Returns whether more is waiting.
    func performBackgroundWork() async -> Bool {
        if pendingChangeCount > 0 { await flushPendingChanges() }
        if outbox.hasPendingWork { outbox.requestFlush() }
        do {
            if try await sync.backfillNextPage() { return true }
            if try await sync.prefetchBodies() > 0 { return true }
            if try await sync.prefetchInlineImages() > 0 { return true }
            // Not in Low Data Mode, but on any other network, cellular included (D24).
            if networkPath?.isConstrained != true,
               try await sync.prefetchAttachments(skipping: hiddenFromSearchMailboxIDs) > 0 {
                return true
            }
            return try await store.performMaintenance()
        } catch {
            return false
        }
    }

    // MARK: Push

    /// Takes in changes as the server pushes them, reconnecting whenever the connection fails or ends.
    private func startPush() {
        stopPush()
        pushTask = Task { [weak self, client] in
            var failures = 0
            while !Task.isCancelled {
                var failure: (any Error)?
                var connectedAt: ContinuousClock.Instant?
                do {
                    let accounts = try await client.session().primaryAccounts
                    guard let types = self?.pushedTypes else { return }
                    for try await event in client.pushEvents(types: types) {
                        // Events already buffered still arrive after cancelling.
                        guard !Task.isCancelled, let self else { return }
                        if event == .connected { connectedAt = .now }
                        receive(event, accounts: accounts)
                    }
                } catch {
                    failure = error
                }
                let lasted = connectedAt.map { ContinuousClock.now - $0 }
                guard !Task.isCancelled,
                      let retry = self?.pushEnded(by: failure, connectedFor: lasted, failures: &failures)
                else { return }
                await retry.value
            }
        }
    }

    /// The types to hear about. Submissions and identities only with a token that may send: asking for them
    /// otherwise fails the connection (§2.8).
    private var pushedTypes: [String] {
        Self.pushedMailTypes + ["MaskedEmail"] + (account?.canSubmit == true ? ["EmailSubmission", "Identity"] : [])
    }

    private func receive(_ event: PushEvent, accounts: [String: String]) {
        switch event {
        case .connected:
            isPushConnected = true
            // Changes made while disconnected are only pushed by a server that knows which ones this client missed.
            requestRefresh()
        case .stateChange(let change):
            let mailTypes = accounts[Capability.mail].flatMap { change.changed[$0] } ?? [:]
            if mailTypes.keys.contains(where: Self.pushedMailTypes.contains) { requestRefresh() }
            if let account = accounts[Capability.maskedEmail], change.changed[account]?["MaskedEmail"] != nil {
                requestMaskedEmailLoad()
            }
            let submissionTypes = accounts[Capability.submission].flatMap { change.changed[$0] } ?? [:]
            if submissionTypes["EmailSubmission"] != nil { outbox.requestFlush() }
            if submissionTypes["Identity"] != nil { requestIdentityLoad() }
        }
    }

    /// Returns the wait before reconnecting, or `nil` when the token was rejected and pushing is over.
    ///
    /// Only a connection that lasted lets the backoff start over: one that a proxy, say, ends right after accepting
    /// it would otherwise have the app connect and catch up every second. Connection trouble isn't reported from
    /// here; refreshing and polling notice it anyway.
    private func pushEnded(
        by error: (any Error)?, connectedFor duration: Duration?, failures: inout Int
    ) -> Task<Void, Never>? {
        isPushConnected = false
        if case JMAPError.unauthorized? = error {
            report(JMAPError.unauthorized)
            return nil
        }
        if let duration, duration >= stablePushConnection { failures = 0 }
        let delay = pushRetryDelay(failures)
        failures += 1
        pushRetry = Task { try? await Task.sleep(for: delay) }
        return pushRetry
    }

    /// Reconnects push right away if it is waiting to retry after a failure, as when the app returns to the
    /// foreground and the network may well be back.
    public func resumePush() {
        pushRetry?.cancel()
    }

    private func stopPush() {
        pushTask?.cancel()
        pushTask = nil
        pushRetry?.cancel()
        isPushConnected = false
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

    /// The mailbox `in:` refers to: a role such as `inbox` or `spam`, else a name, ignoring case.
    public func mailbox(named name: String) -> Mailbox? {
        let role = Mailbox.Role(rawValue: name.lowercased() == "spam" ? "junk" : name.lowercased())
        return mailbox(role) ?? mailboxRows.lazy.map(\.mailbox).first {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// The mailbox the shown list is limited to, if any; triage moves conversations out of it.
    public var listedMailboxID: String? {
        shownQuery?.mailboxID
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
        guard let destination else { return nil }
        var query: ThreadQuery
        switch destination {
        case .mailbox(let id):
            let search = SearchQuery(parsing: searchText)
            let searchesEverywhere = searchScope == .everywhere && search.hasCriteria
            query = ThreadQuery(
                destination: destination, mailboxID: searchesEverywhere ? nil : id, search: search,
                unreadOnly: showsUnreadOnly)
        case .savedSearch(let id):
            guard let saved = savedSearch(id: id) else { return nil }
            query = ThreadQuery(
                destination: destination, mailboxID: saved.mailboxID,
                search: SearchQuery(parsing: saved.query + " " + searchText), unreadOnly: showsUnreadOnly)
        case .maskedEmail, .outbox:
            return nil
        }
        if let name = query.search.mailbox {
            query.mailboxID = mailbox(named: name)?.id
            query.matchesNothing = query.mailboxID == nil
        } else if let id = query.mailboxID, mailbox(id: id) == nil {
            query.matchesNothing = true
        }
        return query
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
        if query.destination != shownQuery?.destination { selectedThreadID = nil }
        if query != shownQuery {
            visibleLimit = Self.pageSize
            serverLoaded = 0
            serverTotal = nil
            pinnedThreadIDs = []
            shownQuery = query
        }
        await showStoredThreads()
        if query.matchesNothing {
            serverTotal = 0
            return
        }

        if debounce, query.search.hasCriteria, isNewSearch {
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
            // A read cancelled because the list it was for has been replaced (another mailbox, say) is no error.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// The store query matching `query`, or `nil` while nothing stored can answer it yet.
    private func storeQuery(for query: ThreadQuery) async throws -> MailStore.ThreadQuery? {
        if query.matchesNothing { return nil }
        guard let mailboxID = query.mailboxID, query.isWholeMailbox else {
            return .init(
                mailboxID: query.mailboxID, hiddenMailboxIDs: query.mailboxID == nil ? hiddenFromSearchMailboxIDs : [],
                search: query.search, unreadOnly: query.unreadOnly)
        }
        // A plain mailbox list must not have gaps, so it only reaches as far back as the copy is complete.
        guard let coverage = try await store.coverage(mailboxID: mailboxID) else { return nil }
        return .init(mailboxID: mailboxID, since: coverage)
    }

    private func filter(for query: ThreadQuery) -> Filter<Email.FilterCondition> {
        typealias Condition = Email.FilterCondition
        var conditions: [Condition] = []
        if let mailboxID = query.mailboxID {
            conditions.append(.init(inMailbox: mailboxID))
        } else if !hiddenFromSearchMailboxIDs.isEmpty {
            conditions.append(.init(inMailboxOtherThan: hiddenFromSearchMailboxIDs))
        }
        let search = query.search
        for term in search.terms {
            let condition = switch term.field {
            case .text: Condition(text: term.value)
            case .from: Condition(from: term.value)
            case .to: Condition(to: term.value)
            case .cc: Condition(cc: term.value)
            case .bcc: Condition(bcc: term.value)
            case .subject: Condition(subject: term.value)
            case .body: Condition(body: term.value)
            }
            conditions.append(condition)
        }
        if query.unreadOnly || search.isUnread == true {
            conditions.append(.init(notKeyword: Email.Keyword.seen.rawValue))
        } else if search.isUnread == false {
            conditions.append(.init(hasKeyword: Email.Keyword.seen.rawValue))
        }
        if let isFlagged = search.isFlagged {
            let flagged = Email.Keyword.flagged.rawValue
            conditions.append(isFlagged ? .init(hasKeyword: flagged) : .init(notKeyword: flagged))
        }
        if let hasAttachment = search.hasAttachment { conditions.append(.init(hasAttachment: hasAttachment)) }
        if let before = search.before { conditions.append(.init(before: before)) }
        if let after = search.after { conditions.append(.init(after: after)) }
        return conditions.count == 1 ? .condition(conditions[0]) : .and(conditions.map { .condition($0) })
    }

    var hiddenFromSearchMailboxIDs: [String] {
        [Mailbox.Role.trash, .junk].compactMap { mailbox($0)?.id }
    }

    private func isListed(_ thread: ThreadSummary, in query: ThreadQuery) -> Bool {
        if let mailboxID = query.mailboxID {
            return thread.emails.contains { $0.mailboxIds?[mailboxID] == true }
        }
        let hidden = Set(hiddenFromSearchMailboxIDs)
        return thread.emails.contains { email in
            !(email.mailboxIds ?? [:]).keys.allSatisfy(hidden.contains)
        }
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

    /// The image a message shows for a `cid:` URL: the stored copy, or else downloaded and kept.
    public func inlineImage(cid: String, in email: Email) async -> (data: Data, type: String)? {
        guard let part = email.inlineImagePart(cid: cid), let blobId = part.blobId, let type = part.type else { return nil }
        if let data = try? await store.inlineImageData(blobId: blobId) { return (data, type) }
        guard let data = try? await client.download(blobId: blobId, type: type, name: part.name ?? "image") else { return nil }
        try? await store.storeInlineImageData(data, blobId: blobId, evictingBeyond: MailStore.inlineImageCacheLimit)
        return (data, type)
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
        return listedMailboxID != archive.id
    }

    public func archive(threadID: String) async {
        guard let archive = mailbox(.archive) else { return }
        await move(threadID: threadID, to: archive.id)
    }

    /// Takes the conversation out of the listed mailbox. In lists spanning all mail, that is wherever
    /// its messages are filed, except that sent messages and drafts stay where they are.
    public func move(threadID: String, to destination: String) async {
        guard let thread = thread(id: threadID) else { return }
        if let source = listedMailboxID {
            guard source != destination else { return }
            let targets = thread.emails.filter { $0.mailboxIds?[source] == true }
            await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .move(from: source, to: destination)) }))
        } else {
            let staying = Set([destination] + [Mailbox.Role.sent, .drafts].compactMap { mailbox($0)?.id })
            let targets = thread.emails.filter { Set(($0.mailboxIds ?? [:]).keys).isDisjoint(with: staying) }
            await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .moveExclusively(to: destination)) }))
        }
    }

    public var canTrash: Bool {
        guard let trash = mailbox(.trash) else { return false }
        return listedMailboxID != trash.id
    }

    public func trash(threadID: String) async {
        guard let thread = thread(id: threadID), let trash = mailbox(.trash) else { return }
        let targets = thread.emails.filter { $0.mailboxIds?[trash.id] != true }
        await apply(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, .moveExclusively(to: trash.id)) }))
    }

    /// Changes the stored emails and the list right away, then sends the change. While the server
    /// can't be reached it waits in the outbox; if the server refuses it, the emails are put back the
    /// way the server has them.
    private func apply(_ updates: [String: PatchObject], userInitiated: Bool = true) async {
        guard !updates.isEmpty else { return }
        let listedBefore = threads.map(\.id)
        do {
            try await sync.enqueue(updates)
        } catch {
            report(error, userInitiated: userInitiated)
            return
        }
        await updatePendingChangeCount()
        await showStoredThreads()
        let removed = Set(listedBefore).subtracting(threads.map(\.id))
        if let selected = selectedThreadID, removed.contains(selected) {
            selectedThreadID = neighbour(of: selected, in: listedBefore, excluding: removed)
        }
        serverLoaded = max(0, serverLoaded - removed.count)
        serverTotal = serverTotal.map { max(0, $0 - removed.count) }
        await flushPendingChanges()
    }

    /// Sends every queued change to emails (the triage outbox).
    ///
    /// Only one flush runs at a time; callers arriving meanwhile wait for it, and it then makes one
    /// more pass so that a change queued after its last look at the outbox isn't left behind.
    private func flushPendingChanges() async {
        await flushes.start { await self.flushOnce() }.value
    }

    private func flushOnce() async {
        do {
            let result = try await sync.flushPendingChanges()
            let refused = result.rejected.filter { $0.value.type != SetError.notFound }.sorted { $0.key < $1.key }
            if let reason = refused.first?.value {
                let messages = refused.count == 1 ? "a message" : "\(refused.count) messages"
                errorMessage = "Fastmail didn't accept a change to \(messages): \(reason.description ?? reason.type)."
            }
            if result.sent > 0 {
                connectionProblem = nil
                if (try? await sync.syncChanges()) == .reset { await loadThreads(debounce: false) }
                await loadMailboxes()
            }
            if result.sent > 0 || !result.rejected.isEmpty { await showStoredThreads() }
        } catch {
            report(error, userInitiated: MailSync.discardsChanges(after: error))
            await showStoredThreads()
        }
        await updatePendingChangeCount()
    }

    private func updatePendingChangeCount() async {
        if let count = try? await store.pendingEmailCount() { pendingChangeCount = count }
    }

    private func neighbour(of threadID: String, in order: [String], excluding removed: Set<String>) -> String? {
        guard let index = order.firstIndex(of: threadID) else { return nil }
        let after = order[(index + 1)...].first { !removed.contains($0) }
        let before = order[..<index].last { !removed.contains($0) }
        return after ?? before
    }

    // MARK: Masked Email

    /// One load at a time, like `refresh()`, so an older answer never replaces a newer one.
    public func loadMaskedEmails() async {
        await requestMaskedEmailLoad().value
    }

    @discardableResult
    private func requestMaskedEmailLoad() -> Task<Void, Never> {
        maskedEmailLoads.start { await self.loadMaskedEmailsOnce() }
    }

    private func loadMaskedEmailsOnce() async {
        do {
            maskedEmails = try await client.maskedEmails()
            try? await store.replaceMaskedEmails(maskedEmails)
        } catch {
            report(error)
        }
    }

    /// The masked address this email was delivered to, if any: where Fastmail says it delivered it
    /// (X-Delivered-To), which also knows a mask reached through Bcc or a list, then the recipients.
    public func maskedEmail(for email: Email) -> MaskedEmail? {
        let recipients = email.deliveredToAddresses + (email.to ?? []) + (email.cc ?? []) + (email.bcc ?? [])
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
        destination = .mailbox(inbox.id)
        searchScope = .everywhere
        searchText = address
    }

    // MARK: Saved searches

    public func savedSearch(id: String) -> SavedSearch? {
        savedSearches.first { $0.id == id }
    }

    public var currentSavedSearch: SavedSearch? {
        guard case .savedSearch(let id) = destination else { return nil }
        return savedSearch(id: id)
    }

    /// What the list currently shows, as a saved search; `nil` unless something is being searched for.
    public var searchToSave: SavedSearch? {
        var parts: [String]
        let mailboxID: String?
        switch destination {
        case .mailbox(let id)?:
            parts = [searchText]
            mailboxID = searchScope == .mailbox ? id : nil
        case .savedSearch(let id)?:
            guard let saved = savedSearch(id: id), !searchText.allSatisfy(\.isWhitespace) || showsUnreadOnly
            else { return nil }
            parts = [saved.query, searchText]
            mailboxID = saved.mailboxID
        default:
            return nil
        }
        if showsUnreadOnly { parts.append("is:unread") }
        let query = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard SearchQuery(parsing: query).hasCriteria else { return nil }
        return SavedSearch(name: query, query: query, mailboxID: mailboxID)
    }

    /// Saves what the list currently shows and switches to the saved search.
    public func saveSearch(named name: String) async {
        guard var search = searchToSave else { return }
        search.name = name
        do {
            try await store.save(search)
            savedSearches.append(search)
            destination = .savedSearch(search.id)
            showsUnreadOnly = false
        } catch {
            report(error, userInitiated: true)
        }
    }

    public func renameSavedSearch(id: String, to name: String) async {
        guard var search = savedSearch(id: id) else { return }
        search.name = name
        do {
            try await store.save(search)
            savedSearches = try await store.savedSearches()
        } catch {
            report(error, userInitiated: true)
        }
    }

    public func deleteSavedSearch(id: String) async {
        do {
            try await store.deleteSavedSearch(id: id)
            savedSearches.removeAll { $0.id == id }
            if destination == .savedSearch(id) {
                destination = nil
                selectInboxIfNeeded()
            }
        } catch {
            report(error, userInitiated: true)
        }
    }

    // MARK: Account

    /// The identities, as last read from the server.
    public var identities: [Identity] {
        account?.identities ?? []
    }

    /// The account as it was last known, before anything is asked of the server (D34).
    private func loadStoredAccount() async {
        guard account == nil, let data = try? await store.keyedData(AccountSnapshot.storeKey),
              let snapshot = try? JSONDecoder().decode(AccountSnapshot.self, from: data)
        else { return }
        account = snapshot
        if username == nil { username = snapshot.username }
    }

    /// Reads the session, and the identities if the token may send, into the account snapshot.
    private func refreshAccount() async {
        guard let session = try? await client.session() else { return }
        username = session.username
        guard let snapshot = AccountSnapshot(session: session, previous: account, at: clock.now) else { return }
        account = snapshot
        await saveAccount()
        if snapshot.canSubmit { await loadIdentities() }
    }

    /// One load at a time, like `refresh()`.
    private func loadIdentities() async {
        await requestIdentityLoad().value
    }

    @discardableResult
    private func requestIdentityLoad() -> Task<Void, Never> {
        identityLoads.start { _ = await self.loadIdentitiesOnce() }
    }

    @discardableResult
    private func loadIdentitiesOnce() async -> Bool {
        guard account?.canSubmit == true, let listed = try? await client.listedIdentities() else { return false }
        await updateAccount { account in
            account.identities = listed.map(\.identity)
            account.hiddenIdentityIDs = listed.filter { !$0.showInCompose }.map(\.id)
        }
        return true
    }

    private func updateAccount(_ change: (inout AccountSnapshot) -> Void) async {
        guard var snapshot = account else { return }
        change(&snapshot)
        snapshot.updatedAt = clock.now
        account = snapshot
        await saveAccount()
    }

    private func saveAccount() async {
        guard let account, let data = try? JSONEncoder().encode(account) else { return }
        try? await store.setKeyedData(data, for: AccountSnapshot.storeKey)
    }

    /// After Replace Token (D18): the client already has the new token. Reads the session, identities and
    /// account again, reconnects push and sends what waits; the store, drafts and outbox stay.
    public func tokenChanged() async {
        let wasPushing = pushTask != nil
        stopPush()
        await refreshAccount()
        if wasPushing { startPush() }
        outbox.requestFlush()
        await refresh()
    }

    // MARK: Network

    /// Follows the network path: when it comes back, push reconnects and waiting mail goes out within
    /// seconds rather than at the next poll (§2.8).
    private func startWatchingNetwork() {
        networkTask?.cancel()
        let paths = network.paths()
        networkTask = Task { [weak self] in
            for await path in paths {
                guard !Task.isCancelled, let self else { return }
                self.networkChanged(to: path)
            }
        }
    }

    private func networkChanged(to path: NetworkPath) {
        let wasOnline = isOnline
        networkPath = path
        isOnline = path.isSatisfied
        if path.isSatisfied, !wasOnline {
            resumePush()
            requestRefresh()
            outbox.connectionReturned()
        } else if wasOnline != path.isSatisfied {
            outbox.rebuildItems()
        }
    }

    // MARK: Background and sign-out

    /// Before the app goes to the background: open composers save on the device and to the server, and the
    /// outbox gets one quick pass (D8, D35).
    public func prepareForBackground() async {
        let end = backgroundActivity.begin("Saving drafts")
        defer { end() }
        for composer in openComposers.values { await composer.saveNow() }
        _ = await outbox.flushNow()
    }

    /// For background tasks (D35): brings the account up to date, makes one outbox pass and checks due holds,
    /// whether or not the app's views ever started this model. Returns whether work remains.
    public func sendPendingMail() async -> Bool {
        let end = backgroundActivity.begin("Sending mail")
        defer { end() }
        await loadStoredAccount()
        if mailboxes.isEmpty { mailboxes = (try? await store.mailboxes()) ?? [] }
        if maskedEmails.isEmpty { maskedEmails = (try? await store.maskedEmails()) ?? [] }
        if networkTask == nil { startWatchingNetwork() }
        await outbox.start()
        await refreshAccount()
        if mailboxes.isEmpty { await loadMailboxes() }
        // The system runs these tasks when there is a network, so a wait for a connection is over.
        await outbox.retryWaitingForConnection()
        return await outbox.flushNow()
    }

    /// What signing out would delete (D36): messages not sent yet and drafts that exist only here.
    public func unsentSummary() async -> UnsentSummary {
        var summary = UnsentSummary(waiting: 0, sending: 0, failed: 0, localOnlyDrafts: 0)
        for row in (try? await store.drafts()) ?? [] {
            switch row.state {
            case .queued: summary.waiting += 1
            case .submitting, .held: summary.sending += 1
            case .failed: summary.failed += 1
            case .editing: if row.hasUnsyncedChanges { summary.localOnlyDrafts += 1 }
            }
        }
        return summary
    }
}

/// What signing out would delete (D36).
public struct UnsentSummary: Sendable, Equatable {
    public var waiting: Int
    /// Being sent or held for Undo.
    public var sending: Int
    public var failed: Int
    /// Drafts with changes Fastmail doesn't have.
    public var localOnlyDrafts: Int

    public init(waiting: Int, sending: Int, failed: Int, localOnlyDrafts: Int) {
        self.waiting = waiting
        self.sending = sending
        self.failed = failed
        self.localOnlyDrafts = localOnlyDrafts
    }

    public var isEmpty: Bool {
        waiting + sending + failed + localOnlyDrafts == 0
    }
}

extension MailModel: OutboxHost {
    var outboxContext: SendContext? {
        guard let drafts = mailbox(.drafts)?.id, let sent = mailbox(.sent)?.id else { return nil }
        return SendContext(
            account: account, directory: senderDirectory,
            mailboxes: SendMailboxes(drafts: drafts, sent: sent, trash: mailbox(.trash)?.id),
            policy: outbox.maskedSending)
    }

    func openComposer(_ id: UUID) -> Composer? {
        openComposers[id]
    }

    func outboxReloadIdentities() async -> SenderDirectory? {
        await loadIdentitiesOnce() ? senderDirectory : nil
    }

    func outboxCreatedIdentity(_ identity: Identity) async {
        await updateAccount { account in
            if !account.identities.contains(where: { $0.id == identity.id }) { account.identities.append(identity) }
        }
    }

    func outboxRefusedHold() async {
        await updateAccount { $0.serverHoldUnsupported = true }
    }

    func outboxLostSubmissionScope() async {
        await updateAccount { $0.canSubmit = false }
    }

    func enqueueTriage(_ updates: [String: PatchObject]) async {
        guard !updates.isEmpty else { return }
        do {
            try await sync.enqueue(updates)
        } catch {
            return
        }
        await updatePendingChangeCount()
        await flushPendingChanges()
    }

    func outboxChangedServer() {
        requestRefresh()
    }

    func outboxTokenRejected() {
        report(JMAPError.unauthorized)
    }
}
