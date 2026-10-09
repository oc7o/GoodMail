import Foundation
import JMAPKit

extension DemoTransport.Store {
    /// `Email/set` (RFC 8621 §4.6): creates, then updates, then destroys, each on its own, so that one failing
    /// leaves the others standing (RFC 8620 §5.3).
    mutating func setEmails(_ arguments: Object, context: inout DemoTransport.RequestContext, now: Date) -> Object {
        var result: Object = ["accountId": .string(DemoTransport.accountId), "oldState": .string(String(state))]
        if case .object(let creates)? = arguments["create"] {
            var created: Object = [:]
            var notCreated: Object = [:]
            for (creationId, value) in creates.sorted(by: { $0.key < $1.key }) {
                switch createEmail(value, now: now) {
                case .created(let email):
                    context.createdIDs[creationId] = DemoTransport.string(email["id"])
                    let serverSet = ["id", "blobId", "threadId", "size"]
                    created[creationId] = .object(email.filter { serverSet.contains($0.key) })
                case .refused(let error):
                    notCreated[creationId] = error
                }
            }
            result["created"] = .object(created)
            if !notCreated.isEmpty { result["notCreated"] = .object(notCreated) }
        }
        if case .object(let updates)? = arguments["update"] {
            var updated: Object = [:]
            var notUpdated: Object = [:]
            for (id, patch) in updates {
                guard let index = emails.firstIndex(where: { $0["id"] == .string(id) }) else {
                    notUpdated[id] = DemoTransport.setError(SetError.notFound)
                    continue
                }
                guard case .object(let patch) = patch else {
                    notUpdated[id] = DemoTransport.setError("invalidPatch")
                    continue
                }
                guard !rejectedEmailIDs.contains(id) else {
                    notUpdated[id] = DemoTransport.setError(
                        SetError.forbidden, description: "Rejected by the demo server")
                    continue
                }
                DemoTransport.apply(patch, to: &emails[index])
                record(id, .updated)
                updated[id] = .null
            }
            result["updated"] = .object(updated)
            if !notUpdated.isEmpty { result["notUpdated"] = .object(notUpdated) }
        }
        if case .array? = arguments["destroy"] {
            var destroyed: [JSONValue] = []
            var notDestroyed: Object = [:]
            for id in DemoTransport.strings(arguments["destroy"]) {
                guard let index = emails.firstIndex(where: { $0["id"] == .string(id) }) else {
                    notDestroyed[id] = DemoTransport.setError(SetError.notFound)
                    continue
                }
                emails.remove(at: index)
                headers[id] = nil
                record(id, .destroyed)
                destroyed.append(.string(id))
            }
            result["destroyed"] = .array(destroyed)
            if !notDestroyed.isEmpty { result["notDestroyed"] = .object(notDestroyed) }
        }
        result["newState"] = .string(String(state))
        return result
    }

    enum EmailCreation {
        case created(Object)
        case refused(JSONValue)
    }

    /// Makes a stored email from an `Email/set` create: its body lists derived from `bodyStructure` as RFC 8621
    /// §4.1.4 describes, and its thread found through the Message-IDs it refers to.
    mutating func createEmail(_ value: JSONValue, now: Date) -> EmailCreation {
        guard case .object(let create) = value else {
            return .refused(DemoTransport.setError(SetError.invalidProperties))
        }
        let mailboxIds = Self.trueKeys(create["mailboxIds"])
        let known = Set(DemoTransport.mailboxes.map(\.id))
        guard !mailboxIds.isEmpty, mailboxIds.allSatisfy(known.contains) else {
            return .refused(DemoTransport.setError(SetError.invalidProperties, properties: ["mailboxIds"]))
        }
        guard case .object(let structure)? = create["bodyStructure"] else {
            return .refused(DemoTransport.setError(SetError.invalidProperties, properties: ["bodyStructure"]))
        }
        let values = DemoMessages.bodyValues(create)
        var check = StructureCheck()
        let root = part(structure, values: values, now: now, check: &check)
        if !check.missingBlobs.isEmpty {
            return .refused(.object([
                "type": .string(SetError.blobNotFound),
                "notFound": .array(check.missingBlobs.uniqued().map(JSONValue.string)),
            ]))
        }
        guard !check.isInvalid else {
            return .refused(DemoTransport.setError(SetError.invalidProperties, properties: ["bodyStructure"]))
        }
        let lists = DemoMessages.bodyLists(of: root)

        let id = makeID("M")
        let messageIds = DemoTransport.strings(create["messageId"])
        let referenced = Set(DemoTransport.strings(create["inReplyTo"]) + DemoTransport.strings(create["references"])
                             + messageIds)
        let threadId = emails.first { !referenced.isDisjoint(with: DemoTransport.strings($0["messageId"])) }
            .map { DemoTransport.string($0["threadId"]) } ?? makeID("T")
        let usedValues = (lists.text + lists.html).compactMap { leaf -> (String, String)? in
            let partId = DemoTransport.string(leaf["partId"])
            return values[partId].map { (partId, $0) }
        }
        let texts = lists.text.compactMap { values[DemoTransport.string($0["partId"])] }
        let preview = texts.isEmpty
            ? lists.html.compactMap { values[DemoTransport.string($0["partId"])] }.joined(separator: " ")
                .replacing(/<style.*?<\/style>|<[^>]+>/.dotMatchesNewlines(), with: " ")
            : texts.joined(separator: " ")
        let size = values.values.reduce(0) { $0 + $1.utf8.count }
            + lists.attachments.reduce(0) { $0 + (DemoTransport.int($1["size"]) ?? 0) }
        var email: Object = [
            "id": .string(id), "blobId": .string("\(id)-blob"), "threadId": .string(threadId),
            "mailboxIds": .object(Dictionary(uniqueKeysWithValues: mailboxIds.map { ($0, true) })),
            "keywords": .object(Dictionary(uniqueKeysWithValues: Self.trueKeys(create["keywords"]).map { ($0, true) })),
            "size": .number(Double(size)), "receivedAt": create["receivedAt"] ?? .string(now.formatted(.iso8601)),
            "sentAt": create["sentAt"] ?? .string(now.formatted(.iso8601)),
            "messageId": messageIds.isEmpty ? [.string("\(id)@demo")] : .array(messageIds.map(JSONValue.string)),
            "sender": .null, "subject": create["subject"] ?? "",
            "preview": .string(String(preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .prefix(256))),
            "hasAttachment": .bool(lists.attachments.contains { DemoTransport.string($0["disposition"]) != "inline" }),
            "textBody": .array(lists.text.map(JSONValue.object)), "htmlBody": .array(lists.html.map(JSONValue.object)),
            "attachments": .array(lists.attachments.map(JSONValue.object)),
            "bodyValues": .object(Dictionary(usedValues.map { partId, text in
                (partId, ["value": .string(text), "isEncodingProblem": false, "isTruncated": false])
            }, uniquingKeysWith: { first, _ in first })),
        ]
        for property in ["inReplyTo", "references", "from", "to", "cc", "bcc", "replyTo"] {
            email[property] = create[property] ?? .null
        }
        // An upload an email refers to stays for good (RFC 8620 §6).
        for blobId in check.blobIds where blobs[blobId] != nil { blobs[blobId]?.expires = nil }
        emails.append(email)
        record(id, .created)
        return .created(email)
    }

    struct StructureCheck {
        var missingBlobs: [String] = []
        var blobIds: [String] = []
        var isInvalid = false
        var leaves = 0
    }

    /// A part of a new email's body as stored: text from `bodyValues`, or a blob with its size.
    private func part(
        _ object: Object, values: [String: String], now: Date, check: inout StructureCheck
    ) -> DemoMessages.Part {
        let type = DemoTransport.string(object["type"]).lowercased()
        let disposition = DemoTransport.string(object["disposition"])
        let name = DemoTransport.string(object["name"])
        if type.hasPrefix("multipart/") {
            var subParts: [DemoMessages.Part] = []
            for subPart in DemoMessages.objects(object["subParts"]) {
                subParts.append(part(subPart, values: values, now: now, check: &check))
            }
            return DemoMessages.Part(leaf: [:], type: type, subParts: subParts)
        }
        check.leaves += 1
        var leaf: Object = [
            "type": .string(type), "name": name.isEmpty ? .null : .string(name),
            "disposition": disposition.isEmpty ? .null : .string(disposition), "cid": object["cid"] ?? .null,
        ]
        if case .string(let partId)? = object["partId"], object["blobId"] == nil {
            guard let text = values[partId] else {
                check.isInvalid = true
                return DemoMessages.Part(leaf: leaf, type: type)
            }
            leaf["partId"] = .string(partId)
            leaf["blobId"] = .null
            leaf["charset"] = "utf-8"
            leaf["size"] = .number(Double(text.utf8.count))
        } else if case .string(let blobId)? = object["blobId"], object["partId"] == nil {
            check.blobIds.append(blobId)
            guard let blob = blob(blobId, now: now) else {
                check.missingBlobs.append(blobId)
                return DemoMessages.Part(leaf: leaf, type: type)
            }
            leaf["partId"] = .string("b\(check.leaves)")
            leaf["blobId"] = .string(blobId)
            leaf["charset"] = object["charset"] ?? .null
            leaf["size"] = .number(Double(blob.data.count))
        } else {
            check.isInvalid = true
        }
        return DemoMessages.Part(
            leaf: leaf, type: type, disposition: disposition.isEmpty ? nil : disposition,
            name: name.isEmpty ? nil : name)
    }

    /// The keys of an `Id[Boolean]` object whose value is `true`.
    static func trueKeys(_ value: JSONValue?) -> [String] {
        guard case .object(let object)? = value else { return [] }
        return object.filter { $0.value == true }.map(\.key).sorted()
    }
}
