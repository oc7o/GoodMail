import Foundation
import JMAPKit
import Synchronization

/// An in-memory stand-in for Fastmail with sample mail, for running the app without an account.
///
/// It understands just the JMAP calls the app makes, and pushes its state changes to event-source
/// connections (RFC 8620 §7.3). The app uses it when launched with `-demo YES`.
public final class DemoTransport: HTTPTransport {
    private typealias Object = [String: JSONValue]

    private struct Change {
        enum Kind { case created, updated, destroyed }
        let state: Int
        let id: String
        let kind: Kind
    }

    /// An open event-source response.
    private struct EventStream {
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        /// The types to push, or `nil` for all of them.
        let types: Set<String>?
        let closesAfterState: Bool
        var lastEvent = ContinuousClock.now
        var pinger: Task<Void, Never>?
    }

    /// What the store has for an event stream, handed over once its lock is released (see `pushLock`).
    private enum Push {
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

    private struct Store {
        var emails: [Object]
        var maskedEmails: [Object]
        var state = 1
        var deliveryState = 1
        var maskedEmailState = 1
        var changes: [Change] = []
        /// Changes up to this state have been forgotten, like a server that pruned its history.
        var oldestKnownState = 0
        var isOffline = false
        var rejectedEmailIDs: Set<String> = []
        var updateRequestCount = 0
        var downloadCount = 0
        /// Types whose state changed since the last push.
        var unpushedTypes: Set<String> = []
        var eventStreams: [Int: EventStream] = [:]
        var eventStreamConnections = 0
        var outbox: [Push] = []

        /// What `Foo/get` returns as `state` for each type; EmailDelivery exists only for push (RFC 8621 §1.5).
        var typeStates: [String: String] {
            Self.typeStates(mail: state, delivery: deliveryState, maskedEmail: maskedEmailState)
        }

        /// Encodes the state of every type, so a reconnecting client's `Last-Event-ID` shows what it missed.
        var eventID: String { "\(state).\(deliveryState).\(maskedEmailState)" }

        static func typeStates(mail: Int, delivery: Int, maskedEmail: Int) -> [String: String] {
            [
                "Email": String(mail), "Thread": String(mail), "Mailbox": String(mail),
                "EmailDelivery": String(delivery), "MaskedEmail": String(maskedEmail),
            ]
        }

        func knows(blobId: String) -> Bool {
            emails.contains { email in
                guard case .array(let parts)? = email["attachments"] else { return false }
                return parts.contains { part in
                    if case .object(let part) = part { part["blobId"] == .string(blobId) } else { false }
                }
            }
        }

        mutating func record(_ id: String, _ kind: Change.Kind) {
            state += 1
            changes.append(Change(state: state, id: id, kind: kind))
            unpushedTypes.formUnion(["Email", "Thread", "Mailbox"])
            if kind == .created {
                deliveryState += 1
                unpushedTypes.insert("EmailDelivery")
            }
        }

        mutating func recordMaskedEmailChange() {
            maskedEmailState += 1
            unpushedTypes.insert("MaskedEmail")
        }

        /// The current states of the types that changed since the event `eventID`; all of them for an id that
        /// isn't one of ours.
        func typeStates(changedSince eventID: String) -> [String: String] {
            let seen = eventID.split(separator: ".").compactMap { Int($0) }
            let old = seen.count == 3 ? Self.typeStates(mail: seen[0], delivery: seen[1], maskedEmail: seen[2]) : [:]
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

    private enum Outcome {
        case result(Object)
        case error(String)
    }

    private static let accountId = "demo"
    private static let mailboxes: [(id: String, name: String, role: String?, parent: String?)] = [
        ("inbox", "Inbox", "inbox", nil), ("archive", "Archive", "archive", nil), ("drafts", "Drafts", "drafts", nil),
        ("sent", "Sent", "sent", nil), ("junk", "Spam", "junk", nil), ("trash", "Trash", "trash", nil),
        ("receipts", "Receipts", nil, nil), ("travel", "Travel", nil, nil), ("lisbon", "Lisbon 2026", nil, "travel"),
    ]

    private let store = Mutex(Store(emails: DemoData.emails, maskedEmails: DemoData.maskedEmails))
    /// Held while the store's outbox is filled and delivered, so every stream gets its events in order.
    ///
    /// Delivering under `store`'s lock instead would deadlock: yielding takes a runtime lock of the consumer's
    /// task, which cancelling the consumer holds while it runs `onTermination`, which takes `store`'s lock.
    private let pushLock = Mutex(())

    public init() {}

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

    /// Emails whose `Email/set` updates are refused with a `forbidden` SetError.
    public var rejectedEmailIDs: Set<String> {
        get { store.withLock { $0.rejectedEmailIDs } }
        set { store.withLock { $0.rejectedEmailIDs = newValue } }
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

    /// Delivers a new plain-text message, as if someone had just sent it.
    public func deliver(id: String, threadId: String, from: String, subject: String, text: String, to mailboxId: String = "inbox") {
        update { store in
            store.emails.append(DemoData.email(
                id, thread: threadId, in: mailboxId, hoursAgo: 0, from: (from, "\(from.lowercased())@example.com"),
                subject: subject, text: text))
            store.record(id, .created)
        }
    }

    /// Permanently deletes an email, as another client would.
    public func destroyEmail(id: String) {
        update { store in
            store.emails.removeAll { $0["id"] == .string(id) }
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
    private func update<Result: Sendable>(_ body: (inout Store) -> Result) -> Result {
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
        let body: Data
        var contentType = "application/json"
        if url.path().hasSuffix("/session") {
            body = Data(DemoData.session.utf8)
        } else if url.path().contains("/download/") {
            // Path: /jmap/download/{accountId}/{blobId}/{name}
            let blobId = url.pathComponents.dropFirst(4).first ?? ""
            guard store.withLock({ $0.knows(blobId: blobId) }) else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            store.withLock { $0.downloadCount += 1 }
            body = Data(DemoData.logo.utf8)
            contentType = "image/svg+xml"
        } else {
            let call = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            body = try JSONEncoder().encode(respond(to: call))
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        return (body, response)
    }

    private func respond(to request: JSONValue) -> JSONValue {
        guard case .object(let envelope) = request, case .array(let calls)? = envelope["methodCalls"] else {
            return ["sessionState": "demo", "methodResponses": []]
        }
        var responses: [JSONValue] = []
        var results: [String: JSONValue] = [:]
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
            switch update({ perform(name, arguments, in: &$0) }) {
            case .result(let result):
                results[id] = .object(result)
                responses.append([.string(name), .object(result), .string(id)])
            case .error(let type):
                responses.append(["error", ["type": .string(type)], .string(id)])
            }
        }
        return ["sessionState": "demo", "methodResponses": .array(responses)]
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

    /// Opens the event source (RFC 8620 §7.3); any other URL streams its `send(_:)` response as one chunk.
    ///
    /// Nothing is pushed on connecting: the RFC asks for that only when the client's `Last-Event-ID` shows it
    /// missed changes.
    public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let url = request.url!
        guard url.path().hasSuffix("/event/") else {
            let (body, response) = try await send(request)
            return (response, AsyncThrowingStream { $0.yield(body); $0.finish() })
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

    private static func event(_ name: String, id: String? = nil, data: JSONValue) -> Data {
        let json = String(decoding: try! JSONEncoder().encode(data), as: UTF8.self)
        return Data("event: \(name)\n\(id.map { "id: \($0)\n" } ?? "")data: \(json)\n\n".utf8)
    }

    // MARK: Methods

    private func perform(_ name: String, _ arguments: Object, in store: inout Store) -> Outcome {
        let base: Object = ["accountId": .string(Self.accountId), "state": .string(String(store.state)), "notFound": []]
        switch name {
        case "Mailbox/get":
            return .result(base.merging(["list": .array(mailboxes(store))]) { $1 })
        case "Email/query":
            return .result(query(arguments, store))
        case "Email/get":
            let properties = Self.strings(arguments["properties"])
            let list = Self.strings(arguments["ids"]).compactMap { id in
                store.emails.first { $0["id"] == .string(id) }
            }.map { email in
                properties.isEmpty ? email : email.filter { $0.key == "id" || properties.contains($0.key) }
            }
            return .result(base.merging(["list": .array(list.map(JSONValue.object))]) { $1 })
        case "Email/changes":
            return changes(arguments, store)
        case "Thread/get":
            let list = Self.strings(arguments["ids"]).uniqued().map { id -> JSONValue in
                let members = store.emails.filter { $0["threadId"] == .string(id) }
                    .sorted { Self.string($0["receivedAt"]) < Self.string($1["receivedAt"]) }
                return ["id": .string(id), "emailIds": .array(members.compactMap { $0["id"] })]
            }
            return .result(base.merging(["list": .array(list)]) { $1 })
        case "Email/set":
            store.updateRequestCount += 1
            guard case .object(let updates)? = arguments["update"] else { return .error("invalidArguments") }
            let oldState = store.state
            var updated: Object = [:]
            var notUpdated: Object = [:]
            for (id, patch) in updates {
                guard let index = store.emails.firstIndex(where: { $0["id"] == .string(id) }) else {
                    notUpdated[id] = ["type": "notFound"]
                    continue
                }
                guard case .object(let patch) = patch else {
                    notUpdated[id] = ["type": "invalidPatch"]
                    continue
                }
                guard !store.rejectedEmailIDs.contains(id) else {
                    notUpdated[id] = ["type": "forbidden", "description": "Rejected by the demo server"]
                    continue
                }
                Self.apply(patch, to: &store.emails[index])
                store.record(id, .updated)
                updated[id] = .null
            }
            var result: Object = [
                "accountId": .string(Self.accountId), "oldState": .string(String(oldState)),
                "newState": .string(String(store.state)), "updated": .object(updated),
            ]
            if !notUpdated.isEmpty { result["notUpdated"] = .object(notUpdated) }
            return .result(result)
        case "MaskedEmail/get":
            let list = JSONValue.array(store.maskedEmails.map(JSONValue.object))
            return .result(base.merging(["state": .string(String(store.maskedEmailState)), "list": list]) { $1 })
        case "MaskedEmail/set":
            return .result(setMaskedEmails(arguments, &store))
        default:
            return .error("unknownMethod")
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

    private func query(_ arguments: Object, _ store: Store) -> Object {
        var matches = store.emails
            .filter { Self.matches($0, arguments["filter"] ?? .null) }
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

    private func changes(_ arguments: Object, _ store: Store) -> Outcome {
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
        return .result([
            "accountId": .string(Self.accountId), "oldState": .string(String(since)),
            "newState": .string(String(store.state)), "hasMoreChanges": false,
            "created": .array(created.map(JSONValue.string)), "updated": .array(updated.map(JSONValue.string)),
            "destroyed": .array(destroyed.map(JSONValue.string)),
        ])
    }

    private static func matches(_ email: Object, _ filter: JSONValue) -> Bool {
        guard case .object(let filter) = filter else { return true }
        if case .string(let op)? = filter["operator"], case .array(let conditions)? = filter["conditions"] {
            switch op {
            case "AND": return conditions.allSatisfy { matches(email, $0) }
            case "OR": return conditions.contains { matches(email, $0) }
            default: return !conditions.contains { matches(email, $0) }
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
            default: true
            }
        }
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
        var text = [string(email["preview"])]
        if case .object(let values)? = email["bodyValues"] {
            for case .object(let value) in values.values { text.append(string(value["value"])) }
        }
        return text.joined(separator: "\n")
    }

    private static func apply(_ patch: Object, to email: inout Object) {
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

    private func setMaskedEmails(_ arguments: Object, _ store: inout Store) -> Object {
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
                    "createdAt": .string(DemoData.date(hoursAgo: 0)), "createdBy": "GoodMail",
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

    private static func string(_ value: JSONValue?) -> String {
        if case .string(let string)? = value { string } else { "" }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.map { string($0) }
    }

    private static func int(_ value: JSONValue?) -> Int? {
        if case .number(let number)? = value { Int(number) } else { nil }
    }

    /// The keys of a JMAP `Id[Boolean]` set such as `mailboxIds` or `keywords`.
    private static func flags(_ value: JSONValue?) -> Set<String> {
        guard case .object(let object)? = value else { return [] }
        return Set(object.keys)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
