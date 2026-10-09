import Foundation
import JMAPKit
import Synchronization

/// An in-memory stand-in for Fastmail with sample mail, for running the app without an account.
///
/// It understands the JMAP calls the app makes, sending included: drafts, uploads, identities with Fastmail's
/// rules for masked addresses, and submissions that it holds and releases on its `DemoClock`, the way Cyrus
/// does. It pushes its state changes to event-source connections (RFC 8620 §7.3). For tests it can also play a
/// failing network, a busy server and other devices. The app uses it when launched with `-demo YES`.
public final class DemoTransport: HTTPTransport {
    typealias Object = [String: JSONValue]

    struct Change {
        enum Kind { case created, updated, destroyed }
        let state: Int
        let id: String
        let kind: Kind
    }

    /// An open event-source response.
    struct EventStream {
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        /// The types to push, or `nil` for all of them.
        let types: Set<String>?
        let closesAfterState: Bool
        var lastEvent = ContinuousClock.now
        var pinger: Task<Void, Never>?
    }

    /// What the store has for an event stream, handed over once its lock is released (see `pushLock`).
    enum Push {
        case event(Data, AsyncThrowingStream<Data, any Error>.Continuation)
        case end(EventStream, (any Error)?)

        func deliver() {
            switch self {
            case .event(let event, let continuation):
                continuation.yield(event)
            case .end(let stream, let error):
                stream.pinger?.cancel()
                stream.continuation.finish(throwing: error)
            }
        }
    }

    /// What goes wrong with the next API request, after the server ran it.
    enum ResponseFault {
        case lost
        case status(Int)
    }

    /// A blob that isn't part of the sample mail: an upload, or one an email was made of.
    struct Blob {
        var data: Data
        var type: String
        /// `nil` once an email refers to it, which keeps it for good (RFC 8620 §6).
        var expires: Date?
    }

    /// One method call's answer: its own, and for `EmailSubmission/set` the implicit `Email/set` after it.
    struct Answer: Sendable {
        let name: String
        let arguments: Object

        static func error(_ type: String, description: String? = nil) -> Answer {
            var arguments: Object = ["type": .string(type)]
            if let description { arguments["description"] = .string(description) }
            return Answer(name: "error", arguments: arguments)
        }
    }

    /// What the calls of one request share: the capabilities it uses, and the ids of what it created so far.
    struct RequestContext {
        let using: Set<String>
        var createdIDs: [String: String] = [:]
    }

    struct Store {
        typealias Object = DemoTransport.Object

        var emails: [Object]
        var maskedEmails: [Object]
        var identities: [Object]
        /// Header fields of emails beyond those their properties make, by email id, topmost first.
        var headers: [String: [DemoHeader]]
        var blobs: [String: Blob] = [:]
        var submissions: [Submission] = []
        var sentMessages: [DemoSentMessage] = []
        var oneClickRequests: [URLRequest] = []
        var supportsSubmission: Bool
        var requiresIdentityForMaskedFrom = true
        var rejectsHoldFor = false
        var ignoresHeaderFilter = false
        var releaseDelay: TimeInterval = 0
        var nextResponseFault: ResponseFault?
        var nextSubmissionMethodError: String?
        var nextSubmissionRejection: SetError?
        /// Pending submissions a task waits to release, on a clock that follows the system clock.
        var scheduledReleases: Set<String> = []
        var nextID = 1
        var state = 1
        var deliveryState = 1
        var maskedEmailState = 1
        var submissionState = 1
        var identityState = 1
        var changes: [Change] = []
        /// Changes up to this state have been forgotten, like a server that pruned its history.
        var oldestKnownState = 0
        var isOffline = false
        var rejectedEmailIDs: Set<String> = []
        var updateRequestCount = 0
        var downloadCount = 0
        var uploadCount = 0
        /// Types whose state changed since the last push.
        var unpushedTypes: Set<String> = []
        var eventStreams: [Int: EventStream] = [:]
        var eventStreamConnections = 0
        var outbox: [Push] = []

        /// What `Foo/get` returns as `state` for each type; EmailDelivery exists only for push (RFC 8621 §1.5).
        var typeStates: [String: String] {
            Self.typeStates([state, deliveryState, maskedEmailState, submissionState, identityState],
                            includesSubmission: supportsSubmission)
        }

        /// Encodes the state of every type, so a reconnecting client's `Last-Event-ID` shows what it missed.
        var eventID: String {
            [state, deliveryState, maskedEmailState, submissionState, identityState].map(String.init)
                .joined(separator: ".")
        }

        static func typeStates(_ states: [Int], includesSubmission: Bool) -> [String: String] {
            var types = [
                "Email": String(states[0]), "Thread": String(states[0]), "Mailbox": String(states[0]),
                "EmailDelivery": String(states[1]), "MaskedEmail": String(states[2]),
            ]
            if includesSubmission {
                types["EmailSubmission"] = String(states[3])
                types["Identity"] = String(states[4])
            }
            return types
        }

        /// An id for an object the server makes: its type's capital letter and a number no other object got.
        /// Seeded ids are lowercase (`e4`, `t2`, `ident-1`), so the two never collide.
        mutating func makeID(_ prefix: String) -> String {
            defer { nextID += 1 }
            return "\(prefix)\(nextID)"
        }

        func email(_ id: String) -> Object? {
            emails.first { $0["id"] == .string(id) }
        }

        /// Every header field of an email, as in its message.
        func allHeaders(of email: Object) -> [DemoHeader] {
            (headers[DemoTransport.string(email["id"])] ?? []) + DemoMessages.standardHeaders(email)
        }

        /// - Parameter isDelivery: Whether the change is new mail arriving, as opposed to a client creating it.
        mutating func record(_ id: String, _ kind: Change.Kind, isDelivery: Bool = false) {
            state += 1
            changes.append(Change(state: state, id: id, kind: kind))
            unpushedTypes.formUnion(["Email", "Thread", "Mailbox"])
            if isDelivery {
                deliveryState += 1
                unpushedTypes.insert("EmailDelivery")
            }
        }

        mutating func recordMaskedEmailChange() {
            maskedEmailState += 1
            unpushedTypes.insert("MaskedEmail")
        }

        mutating func recordSubmissionChange() {
            submissionState += 1
            unpushedTypes.insert("EmailSubmission")
        }

        mutating func recordIdentityChange() {
            identityState += 1
            unpushedTypes.insert("Identity")
        }

        /// The current states of the types that changed since the event `eventID`; all of them for an id that
        /// isn't one of ours.
        func typeStates(changedSince eventID: String) -> [String: String] {
            let seen = eventID.split(separator: ".").compactMap { Int($0) }
            let old = seen.count == 5 ? Self.typeStates(seen, includesSubmission: supportsSubmission) : [:]
            return typeStates.filter { old[$0.key] != $0.value }
        }

        /// Pushes the states of the types changed since the last push.
        mutating func pushStateChange() {
            guard !unpushedTypes.isEmpty else { return }
            let changed = typeStates.filter { unpushedTypes.contains($0.key) }
            unpushedTypes = []
            for id in eventStreams.keys { push(changed, to: id) }
        }

        /// Sends a `state` event with the types the stream asked for, if any.
        mutating func push(_ states: [String: String], to id: Int) {
            guard let stream = eventStreams[id] else { return }
            let states = states.filter { stream.types?.contains($0.key) ?? true }
            guard !states.isEmpty else { return }
            let change: JSONValue = [
                "@type": "StateChange",
                "changed": [DemoTransport.accountId: .object(states.mapValues(JSONValue.string))],
            ]
            send(DemoTransport.event("state", id: eventID, data: change), to: id)
            if stream.closesAfterState { close(id) }
        }

        /// Pings the stream if nothing went out for `seconds`; returns when to look again, or `nil` once it's closed.
        mutating func ping(_ id: Int, every seconds: Int) -> ContinuousClock.Instant? {
            guard let stream = eventStreams[id] else { return nil }
            if stream.lastEvent + .seconds(seconds) <= .now {
                send(DemoTransport.event("ping", data: ["interval": .number(Double(seconds))]), to: id)
            }
            return eventStreams[id]?.lastEvent.advanced(by: .seconds(seconds))
        }

        mutating func send(_ event: Data, to id: Int) {
            guard let continuation = eventStreams[id]?.continuation else { return }
            outbox.append(.event(event, continuation))
            eventStreams[id]?.lastEvent = .now
        }

        mutating func close(_ id: Int, throwing error: (any Error)? = nil) {
            guard let stream = eventStreams.removeValue(forKey: id) else { return }
            outbox.append(.end(stream, error))
        }

        mutating func takeOutbox() -> [Push] {
            defer { outbox = [] }
            return outbox
        }
    }

    static let host = "demo.invalid"
    static let accountId = "demo"
    static let mailboxes: [(id: String, name: String, role: String?, parent: String?)] = [
        ("inbox", "Inbox", "inbox", nil), ("archive", "Archive", "archive", nil), ("drafts", "Drafts", "drafts", nil),
        ("sent", "Sent", "sent", nil), ("junk", "Spam", "junk", nil), ("trash", "Trash", "trash", nil),
        ("receipts", "Receipts", nil, nil), ("travel", "Travel", nil, nil), ("lisbon", "Lisbon 2026", nil, "travel"),
    ]

    /// The URL where the demo newsletter takes one-click unsubscribe requests (see `oneClickRequests`).
    public static var oneClickUnsubscribeURL: URL { DemoData.oneClickURL }

    /// The time everything on this server happens at.
    public let clock: DemoClock
    let store: Mutex<Store>
    /// Held while the store's outbox is filled and delivered, so every stream gets its events in order.
    ///
    /// Delivering under `store`'s lock instead would deadlock: yielding takes a runtime lock of the consumer's
    /// task, which cancelling the consumer holds while it runs `onTermination`, which takes `store`'s lock.
    let pushLock = Mutex(())

    /// - Parameters:
    ///   - clock: A manual clock lets tests move time, such as past the hold of a sent message.
    ///   - supportsSubmission: Whether the token has the "Email submission" scope.
    public init(clock: DemoClock = DemoClock(), supportsSubmission: Bool = true) {
        self.clock = clock
        let now = clock.now
        store = Mutex(Store(
            emails: DemoData.emails(relativeTo: now), maskedEmails: DemoData.maskedEmails(relativeTo: now),
            identities: DemoData.identities, headers: DemoData.headers, supportsSubmission: supportsSubmission))
        clock.addObserver(self)
    }

    // MARK: Simulating the outside world

    /// While offline, every request fails like a dropped connection, and so do the open event streams.
    public var isOffline: Bool {
        get { store.withLock { $0.isOffline } }
        set {
            update { store in
                store.isOffline = newValue
                guard newValue else { return }
                for id in store.eventStreams.keys { store.close(id, throwing: URLError(.networkConnectionLost)) }
            }
        }
    }

    /// Whether the token has the "Email submission" scope. Without it the session leaves submission out, and
    /// every request using it is refused with HTTP 403, as Fastmail does.
    public var supportsSubmission: Bool {
        get { store.withLock { $0.supportsSubmission } }
        set { store.withLock { $0.supportsSubmission = newValue } }
    }

    /// Emails whose `Email/set` updates are refused with a `forbidden` SetError.
    public var rejectedEmailIDs: Set<String> {
        get { store.withLock { $0.rejectedEmailIDs } }
        set { store.withLock { $0.rejectedEmailIDs = newValue } }
    }

    /// Whether `Email/query` ignores the `header` filter, as a server might, and returns everything else.
    public var ignoresHeaderFilter: Bool {
        get { store.withLock { $0.ignoresHeaderFilter } }
        set { store.withLock { $0.ignoresHeaderFilter = newValue } }
    }

    /// How many `Email/set` calls have been received.
    public var updateRequestCount: Int {
        store.withLock { $0.updateRequestCount }
    }

    /// How many blobs have been downloaded.
    public var downloadCount: Int {
        store.withLock { $0.downloadCount }
    }

    /// How many event-source connections are open.
    public var openEventStreams: Int {
        store.withLock { $0.eventStreams.count }
    }

    /// How many event-source connections have been opened in total.
    public var eventStreamConnections: Int {
        store.withLock { $0.eventStreamConnections }
    }

    /// The next API request runs, then fails as if the connection dropped before its answer arrived.
    public func loseNextResponse() {
        store.withLock { $0.nextResponseFault = .lost }
    }

    /// The next API request runs, then is answered with `status` and no body instead of its result, like a
    /// proxy giving up on a slow server (e.g. 503).
    public func answerNext(withStatus status: Int) {
        store.withLock { $0.nextResponseFault = .status(status) }
    }

    /// Delivers a new plain-text message, as if someone had just sent it.
    ///
    /// - Parameters:
    ///   - toAddress: The recipient in To; the login name if `nil`.
    ///   - deliveredTo: The address Fastmail delivered it to, as its `X-Delivered-To` header field names it.
    public func deliver(
        id: String, threadId: String, from: String, subject: String, text: String, to mailboxId: String = "inbox",
        toAddress: String? = nil, deliveredTo: String? = nil
    ) {
        let now = clock.now
        update { store in
            store.emails.append(DemoData.email(
                id, thread: threadId, in: mailboxId, hoursAgo: 0, before: now,
                from: (from, "\(from.lowercased())@example.com"),
                to: toAddress.map { ("", $0) } ?? ("Alex Berg", DemoData.me), subject: subject, text: text))
            if let deliveredTo { store.headers[id] = [DemoHeader("X-Delivered-To", deliveredTo)] }
            store.record(id, .created, isDelivery: true)
        }
    }

    /// Permanently deletes an email, as another client would.
    public func destroyEmail(id: String) {
        update { store in
            store.emails.removeAll { $0["id"] == .string(id) }
            store.headers[id] = nil
            store.record(id, .destroyed)
        }
    }

    /// Changes a masked email's state (e.g. `disabled`), as another client would.
    public func setMaskedEmailState(id: String, to state: String) {
        update { store in
            guard let index = store.maskedEmails.firstIndex(where: { $0["id"] == .string(id) }) else { return }
            store.maskedEmails[index]["state"] = .string(state)
            store.recordMaskedEmailChange()
        }
    }

    /// Makes every state handed out so far too old for `Email/changes`.
    public func forgetChangeHistory() {
        store.withLock { $0.oldestKnownState = $0.state }
    }

    /// Changes the server's data, then pushes the new state of every type that changed.
    func update<Result: Sendable>(_ body: (inout Store) -> Result) -> Result {
        pushLock.withLock { _ in
            let (result, outbox) = store.withLock { store in
                let result = body(&store)
                store.pushStateChange()
                return (result, store.takeOutbox())
            }
            for push in outbox { push.deliver() }
            return result
        }
    }

    // MARK: HTTP

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let url = request.url!
        let path = url.path()
        // Clients ask Fastmail's session URL; the session sends everything else to the demo host.
        if path.hasSuffix("/session") {
            return Self.reply(url, body: Data(DemoData.session(supportsSubmission: supportsSubmission).utf8))
        }
        guard url.host() == Self.host else { return answerElsewhere(request) }
        if path.contains("/download/") { return download(request) }
        if path.contains("/upload/") { return upload(request) }
        return try answerAPIRequest(request)
    }

    private func answerAPIRequest(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let call = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        guard case .object(let envelope) = call else { return Self.reply(url, status: 400) }
        let using = Set(Self.strings(envelope["using"]))
        if using.contains(Capability.submission), !supportsSubmission {
            let problem: JSONValue = [
                "type": "urn:ietf:params:jmap:error:unknownCapability", "status": 403,
                "detail": "This token lacks the Email submission scope.",
            ]
            return Self.reply(url, status: 403, body: try JSONEncoder().encode(problem),
                              type: "application/problem+json")
        }
        let fault = store.withLock { store in
            defer { store.nextResponseFault = nil }
            return store.nextResponseFault
        }
        releaseDueSubmissions()
        let body = try JSONEncoder().encode(respond(to: envelope, using: using))
        scheduleReleases()
        switch fault {
        case .lost?: throw URLError(.networkConnectionLost)
        case .status(let status)?: return Self.reply(url, status: status)
        case nil: return Self.reply(url, body: body)
        }
    }

    /// The demo newsletter's one-click unsubscribe endpoint; any other host isn't found.
    private func answerElsewhere(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        guard request.httpMethod == "POST", url == DemoData.oneClickURL else { return Self.reply(url, status: 404) }
        store.withLock { $0.oneClickRequests.append(request) }
        return Self.reply(url, body: Data(), type: "text/plain")
    }

    static func reply(_ url: URL, status: Int = 200, body: Data = Data(), type: String = "application/json",
                      headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        let fields = ["Content-Type": type].merging(headers) { $1 }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
    }

    private func respond(to envelope: Object, using: Set<String>) -> JSONValue {
        let sessionState = DemoData.sessionState(supportsSubmission: supportsSubmission)
        guard case .array(let calls)? = envelope["methodCalls"] else {
            return ["sessionState": .string(sessionState), "methodResponses": []]
        }
        var responses: [JSONValue] = []
        var results: [String: JSONValue] = [:]
        var context = RequestContext(using: using)
        let now = clock.now
        for call in calls {
            guard case .array(let triple) = call, triple.count == 3, case .string(let name) = triple[0],
                  case .object(var arguments) = triple[1], case .string(let id) = triple[2]
            else { continue }
            for (key, value) in arguments where key.hasPrefix("#") {
                guard case .object(let reference) = value, case .string(let source)? = reference["resultOf"],
                      case .string(let path)? = reference["path"]
                else { continue }
                arguments[String(key.dropFirst())] = Self.resolve(
                    results[source] ?? .null, path: path.split(separator: "/")[...])
                arguments[key] = nil
            }
            let answers = update { store in perform(name, arguments, in: &store, context: &context, now: now) }
            for answer in answers {
                if results[id] == nil, answer.name != "error" { results[id] = .object(answer.arguments) }
                responses.append([.string(answer.name), .object(answer.arguments), .string(id)])
            }
        }
        return ["sessionState": .string(sessionState), "methodResponses": .array(responses)]
    }

    /// Evaluates a JSON Pointer with `*` wildcards (RFC 8620 §3.7).
    private static func resolve(_ value: JSONValue, path: ArraySlice<Substring>) -> JSONValue {
        guard let head = path.first else { return value }
        let rest = path.dropFirst()
        switch value {
        case .array(let items) where head == "*":
            return .array(items.flatMap { item -> [JSONValue] in
                if case .array(let nested) = resolve(item, path: rest) { return nested }
                return [resolve(item, path: rest)]
            })
        case .object(let object):
            return resolve(object[String(head)] ?? .null, path: rest)
        default:
            return .null
        }
    }

    // MARK: Push

    /// Opens the event source (RFC 8620 §7.3); any other URL streams its `send(_:)` response, a download in
    /// chunks of 64 KiB.
    ///
    /// Nothing is pushed on connecting: the RFC asks for that only when the client's `Last-Event-ID` shows it
    /// missed changes.
    public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let url = request.url!
        guard url.path().hasSuffix("/event/") else {
            let (body, response) = try await send(request)
            return (response, AsyncThrowingStream { continuation in
                var offset = body.startIndex
                while offset < body.endIndex {
                    let end = body.index(offset, offsetBy: 65_536, limitedBy: body.endIndex) ?? body.endIndex
                    continuation.yield(Data(body[offset..<end]))
                    offset = end
                }
                continuation.finish()
            })
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func parameter(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let types = parameter("types").flatMap { $0 == "*" ? nil : Set($0.split(separator: ",").map(String.init)) }
        let closesAfterState = parameter("closeafter") == "state"
        let pingSeconds = max(parameter("ping").flatMap { Int($0) } ?? 0, 0)
        let lastEventID = request.value(forHTTPHeaderField: "Last-Event-ID")
        let (events, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let isOpen = update { store in
            guard !store.isOffline else { return false }
            store.eventStreamConnections += 1
            let id = store.eventStreamConnections
            continuation.onTermination = { [weak self] _ in self?.closeEventStream(id) }
            store.eventStreams[id] = EventStream(
                continuation: continuation, types: types, closesAfterState: closesAfterState,
                pinger: pingSeconds > 0 ? Task { await self.ping(id, every: pingSeconds) } : nil)
            if let lastEventID { store.push(store.typeStates(changedSince: lastEventID), to: id) }
            return true
        }
        guard isOpen else { throw URLError(.notConnectedToInternet) }
        let headers = ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, events)
    }

    /// Sends `ping` events while the stream is open, each `seconds` after the event before.
    private func ping(_ id: Int, every seconds: Int) async {
        var due = ContinuousClock.now + .seconds(seconds)
        while (try? await Task.sleep(until: due, clock: .continuous)) != nil {
            guard let next = update({ $0.ping(id, every: seconds) }) else { return }
            due = next
        }
    }

    /// Runs as `onTermination`, so it must only take `store`'s lock (see `pushLock`).
    private func closeEventStream(_ id: Int) {
        store.withLock { $0.eventStreams.removeValue(forKey: id) }?.pinger?.cancel()
    }

    static func event(_ name: String, id: String? = nil, data: JSONValue) -> Data {
        let json = String(decoding: try! JSONEncoder().encode(data), as: UTF8.self)
        return Data("event: \(name)\n\(id.map { "id: \($0)\n" } ?? "")data: \(json)\n\n".utf8)
    }

    // MARK: Methods

    private func perform(
        _ name: String, _ arguments: Object, in store: inout Store, context: inout RequestContext, now: Date
    ) -> [Answer] {
        let base: Object = ["accountId": .string(Self.accountId), "state": .string(String(store.state))]
        switch name {
        case "Mailbox/get":
            let list: Object = ["list": .array(mailboxes(store)), "notFound": []]
            return [Answer(name: name, arguments: base.merging(list) { $1 })]
        case "Email/query":
            return [Answer(name: name, arguments: query(arguments, store))]
        case "Email/get":
            return [Answer(name: name, arguments: base.merging(getEmails(arguments, store)) { $1 })]
        case "Email/changes":
            return [changes(arguments, store)]
        case "Thread/get":
            let list = Self.strings(arguments["ids"]).uniqued().map { id -> JSONValue in
                let members = store.emails.filter { $0["threadId"] == .string(id) }
                    .sorted { Self.string($0["receivedAt"]) < Self.string($1["receivedAt"]) }
                return ["id": .string(id), "emailIds": .array(members.compactMap { $0["id"] })]
            }
            return [Answer(name: name, arguments: base.merging(["list": .array(list), "notFound": []]) { $1 })]
        case "Email/set":
            store.updateRequestCount += 1
            return [Answer(name: name, arguments: store.setEmails(arguments, context: &context, now: now))]
        case "MaskedEmail/get":
            let list = JSONValue.array(store.maskedEmails.map(JSONValue.object))
            return [Answer(name: name, arguments: base.merging([
                "state": .string(String(store.maskedEmailState)), "list": list, "notFound": [],
            ]) { $1 })]
        case "MaskedEmail/set":
            return [Answer(name: name, arguments: setMaskedEmails(arguments, &store, now: now))]
        case "Identity/get":
            return [Answer(name: name, arguments: store.getIdentities(arguments))]
        case "Identity/set":
            return [Answer(name: name, arguments: store.setIdentities(arguments, context: &context))]
        case "EmailSubmission/get":
            return [Answer(name: name, arguments: store.getSubmissions(arguments))]
        case "EmailSubmission/query":
            return [Answer(name: name, arguments: store.querySubmissions(arguments))]
        case "EmailSubmission/set":
            return store.setSubmissions(arguments, context: &context, now: now)
        default:
            return [.error("unknownMethod")]
        }
    }

    private func mailboxes(_ store: Store) -> [JSONValue] {
        Self.mailboxes.enumerated().map { index, mailbox in
            let emails = store.emails.filter { Self.flags($0["mailboxIds"]).contains(mailbox.id) }
            let unread = emails.filter { !Self.flags($0["keywords"]).contains("$seen") }
            func threads(_ emails: [Object]) -> Int { Set(emails.map { Self.string($0["threadId"]) }).count }
            return [
                "id": .string(mailbox.id), "name": .string(mailbox.name),
                "role": mailbox.role.map(JSONValue.string) ?? .null,
                "parentId": mailbox.parent.map(JSONValue.string) ?? .null,
                "sortOrder": .number(Double(index)), "isSubscribed": true,
                "totalEmails": .number(Double(emails.count)), "unreadEmails": .number(Double(unread.count)),
                "totalThreads": .number(Double(threads(emails))), "unreadThreads": .number(Double(threads(unread))),
            ]
        }
    }

    /// Asked-for `header:` properties are made from the email's header fields, and `headers` lists them all in
    /// raw form, as its message has them apart from the MIME fields of the body (RFC 8621 §4.1.3).
    private func getEmails(_ arguments: Object, _ store: Store) -> Object {
        let properties = Self.strings(arguments["properties"])
        var list: [JSONValue] = []
        var notFound: [JSONValue] = []
        for id in Self.strings(arguments["ids"]) {
            guard let email = store.email(id) else {
                notFound.append(.string(id))
                continue
            }
            guard !properties.isEmpty else {
                list.append(.object(email))
                continue
            }
            var result = email.filter { $0.key == "id" || properties.contains($0.key) }
            let headers = store.allHeaders(of: email)
            for property in properties where property.hasPrefix("header:") {
                result[property] = DemoMessages.headerProperty(property, of: headers)
            }
            if properties.contains("headers") {
                let fields = (store.headers[id] ?? []) + DemoMessages.standardHeaders(email, encoded: true)
                result["headers"] = .array(fields.map { ["name": .string($0.name), "value": .string(" " + $0.value)] })
            }
            list.append(.object(result))
        }
        return ["list": .array(list), "notFound": .array(notFound)]
    }

    private func query(_ arguments: Object, _ store: Store) -> Object {
        var matches = store.emails
            .filter { Self.matches($0, arguments["filter"] ?? .null, store) }
            .sorted { Self.string($0["receivedAt"]) > Self.string($1["receivedAt"]) }
        if arguments["collapseThreads"] == true {
            var seen = Set<String>()
            matches = matches.filter { seen.insert(Self.string($0["threadId"])).inserted }
        }
        let position = Self.int(arguments["position"]) ?? 0
        let limit = Self.int(arguments["limit"]) ?? matches.count
        let page = matches.dropFirst(position).prefix(limit)
        return [
            "accountId": .string(Self.accountId), "queryState": "demo", "canCalculateChanges": false,
            "position": .number(Double(position)), "total": .number(Double(matches.count)),
            "ids": .array(page.compactMap { $0["id"] }),
        ]
    }

    private func changes(_ arguments: Object, _ store: Store) -> Answer {
        guard let since = Int(Self.string(arguments["sinceState"])), since >= store.oldestKnownState,
              since <= store.state
        else { return .error("cannotCalculateChanges") }

        var created: [String] = []
        var updated: [String] = []
        var destroyed: [String] = []
        let recent = store.changes.filter { $0.state > since }
        for id in recent.map(\.id).uniqued() {
            let kinds = recent.filter { $0.id == id }.map(\.kind)
            switch (kinds.contains(.created), kinds.contains(.destroyed)) {
            case (true, true): break
            case (true, false): created.append(id)
            case (false, true): destroyed.append(id)
            case (false, false): updated.append(id)
            }
        }
        return Answer(name: "Email/changes", arguments: [
            "accountId": .string(Self.accountId), "oldState": .string(String(since)),
            "newState": .string(String(store.state)), "hasMoreChanges": false,
            "created": .array(created.map(JSONValue.string)), "updated": .array(updated.map(JSONValue.string)),
            "destroyed": .array(destroyed.map(JSONValue.string)),
        ])
    }

    private static func matches(_ email: Object, _ filter: JSONValue, _ store: Store) -> Bool {
        guard case .object(let filter) = filter else { return true }
        if case .string(let op)? = filter["operator"], case .array(let conditions)? = filter["conditions"] {
            switch op {
            case "AND": return conditions.allSatisfy { matches(email, $0, store) }
            case "OR": return conditions.contains { matches(email, $0, store) }
            default: return !conditions.contains { matches(email, $0, store) }
            }
        }
        let mailboxes = flags(email["mailboxIds"])
        return filter.allSatisfy { key, value in
            switch key {
            case "inMailbox": mailboxes.contains(string(value))
            case "inMailboxOtherThan": !mailboxes.isSubset(of: strings(value))
            case "notKeyword": !flags(email["keywords"]).contains(string(value))
            case "hasKeyword": flags(email["keywords"]).contains(string(value))
            case "text": searchableText(email).localizedCaseInsensitiveContains(string(value))
            case "from", "to", "cc", "bcc": addressText(email[key]).localizedCaseInsensitiveContains(string(value))
            case "subject": string(email["subject"]).localizedCaseInsensitiveContains(string(value))
            case "body": bodyText(email).localizedCaseInsensitiveContains(string(value))
            case "hasAttachment": email["hasAttachment"] == value
            // Both sides are ISO 8601 in UTC, which sorts as text.
            case "before": string(email["receivedAt"]) < string(value)
            case "after": string(email["receivedAt"]) >= string(value)
            case "header": store.ignoresHeaderFilter || hasHeader(strings(value), in: store.allHeaders(of: email))
            default: true
            }
        }
    }

    /// `[name]` matches when the field is present, `[name, text]` when a field of that name contains the text.
    private static func hasHeader(_ condition: [String], in headers: [DemoHeader]) -> Bool {
        guard let name = condition.first?.lowercased() else { return true }
        let fields = headers.filter { $0.name.lowercased() == name }
        guard condition.count > 1 else { return !fields.isEmpty }
        return fields.contains { $0.value.localizedCaseInsensitiveContains(condition[1]) }
    }

    private static func searchableText(_ email: Object) -> String {
        ([string(email["subject"]), bodyText(email)] + ["from", "to", "cc"].map { addressText(email[$0]) })
            .joined(separator: "\n")
    }

    private static func addressText(_ value: JSONValue?) -> String {
        guard case .array(let addresses)? = value else { return "" }
        return addresses.compactMap { address -> String? in
            guard case .object(let address) = address else { return nil }
            return string(address["name"]) + " " + string(address["email"])
        }.joined(separator: "\n")
    }

    private static func bodyText(_ email: Object) -> String {
        ([string(email["preview"])] + DemoMessages.bodyValues(email).values).joined(separator: "\n")
    }

    static func apply(_ patch: Object, to email: inout Object) {
        for (path, value) in patch {
            let components = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2 else {
                email[path] = value
                continue
            }
            guard case .object(var flags) = email[components[0]] ?? .object([:]) else { continue }
            let key = components[1].replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            // Not `flags[key] = nil`: JSONValue is nil-literal convertible, so that would store a JSON null.
            if value == .null {
                flags.removeValue(forKey: key)
            } else {
                flags[key] = value
            }
            email[components[0]] = .object(flags)
        }
    }

    private func setMaskedEmails(_ arguments: Object, _ store: inout Store, now: Date) -> Object {
        let before = store.maskedEmails
        var result: Object = ["accountId": .string(Self.accountId), "oldState": .string(String(store.maskedEmailState))]
        if case .object(let creates)? = arguments["create"] {
            var created: Object = [:]
            for (creationId, value) in creates {
                guard case .object(var masked) = value else { continue }
                let requested = Self.string(masked["emailPrefix"])
                let prefix = requested.isEmpty ? "quiet.harbor" : requested
                let server: Object = [
                    "id": .string("masked-\(store.maskedEmails.count + 1)"),
                    "email": .string("\(prefix).\(Int.random(in: 1000...9999))@fastmail.com"),
                    "createdAt": .string(DemoData.date(hoursAgo: 0, before: now)), "createdBy": "GoodMail",
                    "lastMessageAt": .null,
                ]
                masked.merge(server) { $1 }
                store.maskedEmails.append(masked)
                created[creationId] = .object(server)
            }
            result["created"] = .object(created)
        }
        if case .object(let updates)? = arguments["update"] {
            for (id, patch) in updates {
                guard let index = store.maskedEmails.firstIndex(where: { $0["id"] == .string(id) }),
                      case .object(let patch) = patch
                else { continue }
                store.maskedEmails[index].merge(patch) { $1 }
            }
            result["updated"] = .object(updates.mapValues { _ in .null })
        }
        if store.maskedEmails != before { store.recordMaskedEmailChange() }
        result["newState"] = .string(String(store.maskedEmailState))
        return result
    }

    // MARK: JSON helpers

    static func string(_ value: JSONValue?) -> String {
        DemoMessages.string(value)
    }

    static func strings(_ value: JSONValue?) -> [String] {
        DemoMessages.strings(value)
    }

    static func int(_ value: JSONValue?) -> Int? {
        if case .number(let number)? = value { Int(number) } else { nil }
    }

    /// The keys of a JMAP `Id[Boolean]` set such as `mailboxIds` or `keywords`.
    static func flags(_ value: JSONValue?) -> Set<String> {
        guard case .object(let object)? = value else { return [] }
        return Set(object.keys)
    }

    static func setError(_ type: String, description: String? = nil, properties: [String]? = nil) -> JSONValue {
        var error: Object = ["type": .string(type)]
        if let description { error["description"] = .string(description) }
        if let properties { error["properties"] = .array(properties.map(JSONValue.string)) }
        return .object(error)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
