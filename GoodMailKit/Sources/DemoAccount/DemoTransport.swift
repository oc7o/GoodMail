import Foundation
import JMAPKit
import Synchronization

/// An in-memory stand-in for Fastmail with sample mail, for running the app without an account.
///
/// It understands just the JMAP calls the app makes. The app uses it when launched with `-demo YES`.
public final class DemoTransport: HTTPTransport {
    private typealias Object = [String: JSONValue]

    private struct Change {
        enum Kind { case created, updated, destroyed }
        let state: Int
        let id: String
        let kind: Kind
    }

    private struct Store {
        var emails: [Object]
        var maskedEmails: [Object]
        var state = 1
        var changes: [Change] = []
        /// Changes up to this state have been forgotten, like a server that pruned its history.
        var oldestKnownState = 0
        var isOffline = false
        var rejectedEmailIDs: Set<String> = []
        var updateRequestCount = 0

        mutating func record(_ id: String, _ kind: Change.Kind) {
            state += 1
            changes.append(Change(state: state, id: id, kind: kind))
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

    public init() {}

    // MARK: Simulating the outside world

    /// While offline, every request fails like a dropped connection.
    public var isOffline: Bool {
        get { store.withLock { $0.isOffline } }
        set { store.withLock { $0.isOffline = newValue } }
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

    /// Delivers a new plain-text message, as if someone had just sent it.
    public func deliver(id: String, threadId: String, from: String, subject: String, text: String, to mailboxId: String = "inbox") {
        store.withLock { store in
            store.emails.append(DemoData.email(
                id, thread: threadId, in: mailboxId, hoursAgo: 0, from: (from, "\(from.lowercased())@example.com"),
                subject: subject, text: text))
            store.record(id, .created)
        }
    }

    /// Permanently deletes an email, as another client would.
    public func destroyEmail(id: String) {
        store.withLock { store in
            store.emails.removeAll { $0["id"] == .string(id) }
            store.record(id, .destroyed)
        }
    }

    /// Makes every state handed out so far too old for `Email/changes`.
    public func forgetChangeHistory() {
        store.withLock { $0.oldestKnownState = $0.state }
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
            switch store.withLock({ perform(name, arguments, in: &$0) }) {
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
            return .result(base.merging(["list": .array(store.maskedEmails.map(JSONValue.object))]) { $1 })
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
        var result: Object = ["accountId": .string(Self.accountId), "newState": "demo"]
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
