import Foundation
import JMAPKit
import Synchronization

/// An in-memory stand-in for Fastmail with sample mail, for running the app without an account.
///
/// It understands just the JMAP calls the app makes. The app uses it when launched with `-demo YES`.
public final class DemoTransport: HTTPTransport {
    private typealias Object = [String: JSONValue]

    private struct Store {
        var emails: [Object]
        var maskedEmails: [Object]
    }

    private static let accountId = "demo"
    private static let mailboxes: [(id: String, name: String, role: String?, parent: String?)] = [
        ("inbox", "Inbox", "inbox", nil), ("archive", "Archive", "archive", nil), ("drafts", "Drafts", "drafts", nil),
        ("sent", "Sent", "sent", nil), ("junk", "Spam", "junk", nil), ("trash", "Trash", "trash", nil),
        ("receipts", "Receipts", nil, nil), ("travel", "Travel", nil, nil), ("lisbon", "Lisbon 2026", nil, "travel"),
    ]

    private let store = Mutex(Store(emails: DemoData.emails, maskedEmails: DemoData.maskedEmails))

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
            if let result = store.withLock({ perform(name, arguments, in: &$0) }) {
                results[id] = .object(result)
                responses.append([.string(name), .object(result), .string(id)])
            } else {
                responses.append(["error", ["type": "unknownMethod"], .string(id)])
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

    private func perform(_ name: String, _ arguments: Object, in store: inout Store) -> Object? {
        let base: Object = ["accountId": .string(Self.accountId), "state": "demo", "notFound": []]
        switch name {
        case "Mailbox/get":
            return base.merging(["list": .array(mailboxes(store))]) { $1 }
        case "Email/query":
            return query(arguments, store)
        case "Email/get":
            let properties = Self.strings(arguments["properties"])
            let list = Self.strings(arguments["ids"]).compactMap { id in
                store.emails.first { $0["id"] == .string(id) }
            }.map { email in
                properties.isEmpty ? email : email.filter { $0.key == "id" || properties.contains($0.key) }
            }
            return base.merging(["list": .array(list.map(JSONValue.object))]) { $1 }
        case "Thread/get":
            let list = Self.strings(arguments["ids"]).uniqued().map { id -> JSONValue in
                let members = store.emails.filter { $0["threadId"] == .string(id) }
                    .sorted { Self.string($0["receivedAt"]) < Self.string($1["receivedAt"]) }
                return ["id": .string(id), "emailIds": .array(members.compactMap { $0["id"] })]
            }
            return base.merging(["list": .array(list)]) { $1 }
        case "Email/set":
            guard case .object(let updates)? = arguments["update"] else { return nil }
            for (id, patch) in updates {
                guard let index = store.emails.firstIndex(where: { $0["id"] == .string(id) }),
                      case .object(let patch) = patch
                else { continue }
                Self.apply(patch, to: &store.emails[index])
            }
            return [
                "accountId": .string(Self.accountId), "newState": "demo",
                "updated": .object(updates.mapValues { _ in .null }),
            ]
        case "MaskedEmail/get":
            return base.merging(["list": .array(store.maskedEmails.map(JSONValue.object))]) { $1 }
        case "MaskedEmail/set":
            return setMaskedEmails(arguments, &store)
        default:
            return nil
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
            default: true
            }
        }
    }

    private static func searchableText(_ email: Object) -> String {
        var text = [string(email["subject"]), string(email["preview"])]
        for key in ["from", "to", "cc"] {
            guard case .array(let addresses)? = email[key] else { continue }
            for case .object(let address) in addresses {
                text += [string(address["name"]), string(address["email"])]
            }
        }
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
            // Not `flags[key] = nil`: JSONValue is nil-literal convertible, so that would store a JSON null.
            if value == .null {
                flags.removeValue(forKey: components[1])
            } else {
                flags[components[1]] = value
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
