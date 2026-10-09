import Foundation
import JMAPKit

/// A message the demo server sent: a submission it released.
public struct DemoSentMessage: Sendable, Equatable {
    public let submissionId: String
    public let emailId: String
    public let identityId: String
    /// The address in the From header field.
    public let from: String
    /// The envelope sender, which recipients see as Return-Path.
    public let mailFrom: String
    public let rcptTo: [String]
    public let subject: String
    public let messageId: String?
    public let sentAt: Date

    public init(
        submissionId: String, emailId: String, identityId: String, from: String, mailFrom: String, rcptTo: [String],
        subject: String, messageId: String?, sentAt: Date
    ) {
        self.submissionId = submissionId
        self.emailId = emailId
        self.identityId = identityId
        self.from = from
        self.mailFrom = mailFrom
        self.rcptTo = rcptTo
        self.subject = subject
        self.messageId = messageId
        self.sentAt = sentAt
    }
}

/// A held submission (RFC 8621 §7). Like Fastmail, the server deletes a submission once it is released or
/// cancelled, so only these exist.
struct Submission {
    let id: String
    let identityId: String
    let emailId: String
    let threadId: String?
    let envelope: JSONValue
    let mailFrom: String
    let rcptTo: [String]
    let sendAt: Date
    /// The email as submitted: what goes out, even if the email is destroyed meanwhile (RFC 8621 §7.5).
    let email: [String: JSONValue]
}

extension DemoTransport: DemoClockObserver {
    func clockAdvanced() {
        releaseDueSubmissions()
    }
}

extension DemoTransport {
    /// Whether sending from a masked address needs an identity with exactly that address, or a wildcard one for
    /// its domain. Without that, any identity may send from any masked address of the account.
    public var requiresIdentityForMaskedFrom: Bool {
        get { store.withLock { $0.requiresIdentityForMaskedFrom } }
        set { store.withLock { $0.requiresIdentityForMaskedFrom = newValue } }
    }

    /// Whether `HOLDFOR` is refused (`invalidProperties` naming `envelope`), as by a server that can't hold mail.
    public var rejectsHoldFor: Bool {
        get { store.withLock { $0.rejectsHoldFor } }
        set { store.withLock { $0.rejectsHoldFor = newValue } }
    }

    /// Seconds a held message stays pending past its `sendAt`, as Fastmail's release lags a little behind.
    public var releaseDelay: TimeInterval {
        get { store.withLock { $0.releaseDelay } }
        set { store.withLock { $0.releaseDelay = newValue } }
    }

    /// The submissions held and not yet released, the earliest due first.
    public var pendingSubmissionIDs: [String] {
        store.withLock { $0.submissions.sorted { $0.sendAt < $1.sendAt }.map(\.id) }
    }

    /// Every message released so far, in order. A message another device sent is not among them.
    public var sentMessages: [DemoSentMessage] {
        store.withLock { $0.sentMessages }
    }

    /// The one-click unsubscribe requests the demo newsletter received (see `oneClickUnsubscribeURL`).
    public var oneClickRequests: [URLRequest] {
        store.withLock { $0.oneClickRequests }
    }

    /// Advances the clock: messages held until then are released, and the changes pushed.
    public func advanceClock(by seconds: TimeInterval) {
        clock.advance(by: seconds)
    }

    /// The next `EmailSubmission/set` call is answered with a method error of `type`, such as
    /// `serverUnavailable`; calls before it in the same request, such as the `Email/set` creating the message,
    /// run as usual.
    public func failNextSubmission(methodError type: String) {
        store.withLock { $0.nextSubmissionMethodError = type }
    }

    /// The next submission the server is asked to create is refused with `error`, such as `tooLarge` or
    /// `forbiddenToSend`.
    public func rejectNextSubmission(_ error: SetError) {
        store.withLock { $0.nextSubmissionRejection = error }
    }

    func releaseDueSubmissions() {
        let now = clock.now
        update { $0.releaseDue(now: now) }
    }

    /// Nothing advances a clock that follows the system clock, so each held message gets a task that releases it
    /// when it's due.
    func scheduleReleases() {
        guard !clock.isManual else { return }
        let held = store.withLock { store in
            let held = store.submissions.filter { !store.scheduledReleases.contains($0.id) }
            store.scheduledReleases.formUnion(held.map(\.id))
            return held.map { (id: $0.id, sendAt: $0.sendAt) }
        }
        for submission in held {
            Task { [weak self] in
                while let self {
                    let delay = store.withLock { store in
                        store.submissions.contains { $0.id == submission.id } ? store.releaseDelay : nil
                    }
                    guard let delay else { return }
                    await clock.wait(until: submission.sendAt.addingTimeInterval(delay))
                    releaseDueSubmissions()
                }
            }
        }
    }
}

extension DemoTransport.Store {
    // MARK: Identities

    func getIdentities(_ arguments: Object) -> Object {
        let (list, notFound) = Self.select(identities, ids: arguments["ids"], properties: arguments["properties"])
        return [
            "accountId": .string(DemoTransport.accountId), "state": .string(String(identityState)),
            "list": .array(list), "notFound": .array(notFound),
        ]
    }

    /// Creating an identity only works for an enabled masked address of the account; anything else is
    /// `forbiddenFrom`. Identities can't be changed or deleted here.
    mutating func setIdentities(_ arguments: Object, context: inout DemoTransport.RequestContext) -> Object {
        var result: Object = ["accountId": .string(DemoTransport.accountId), "oldState": .string(String(identityState))]
        if case .object(let creates)? = arguments["create"] {
            var created: Object = [:]
            var notCreated: Object = [:]
            for (creationId, value) in creates.sorted(by: { $0.key < $1.key }) {
                guard case .object(let create) = value, case .string(let email)? = create["email"] else {
                    notCreated[creationId] = DemoTransport.setError(SetError.invalidProperties, properties: ["email"])
                    continue
                }
                let isEnabledMask = maskedEmails.contains {
                    DemoTransport.string($0["email"]).lowercased() == email.lowercased()
                        && DemoTransport.string($0["state"]) == MaskedEmail.State.enabled.rawValue
                }
                guard isEnabledMask else {
                    notCreated[creationId] = DemoTransport.setError(
                        SetError.forbiddenFrom, description: "You can't send from \(email).")
                    continue
                }
                let id = makeID("ident-")
                identities.append([
                    "id": .string(id), "name": .string(DemoTransport.string(create["name"])), "email": .string(email),
                    "replyTo": .null, "bcc": .null, "textSignature": "", "htmlSignature": "", "mayDelete": true,
                ])
                created[creationId] = ["id": .string(id), "mayDelete": true]
                context.createdIDs[creationId] = id
            }
            result["created"] = .object(created)
            if !notCreated.isEmpty { result["notCreated"] = .object(notCreated) }
            if !created.isEmpty { recordIdentityChange() }
        }
        let refused = DemoTransport.setError(SetError.forbidden, description: "Identities can't be changed here.")
        if case .object(let updates)? = arguments["update"] {
            result["notUpdated"] = .object(updates.mapValues { _ in refused })
        }
        let destroys = DemoTransport.strings(arguments["destroy"])
        if !destroys.isEmpty {
            result["notDestroyed"] = .object(Dictionary(uniqueKeysWithValues: destroys.map { ($0, refused) }))
        }
        result["newState"] = .string(String(identityState))
        return result
    }

    // MARK: Submissions

    func getSubmissions(_ arguments: Object) -> Object {
        let (list, notFound) = Self.select(
            submissions.map(Self.object), ids: arguments["ids"], properties: arguments["properties"])
        return [
            "accountId": .string(DemoTransport.accountId), "state": .string(String(submissionState)),
            "list": .array(list), "notFound": .array(notFound),
        ]
    }

    /// Supports a single filter condition with `emailIds`, `identityIds`, `threadIds`, `undoStatus`, `before` and
    /// `after`.
    func querySubmissions(_ arguments: Object) -> Object {
        let filter: Object = if case .object(let filter)? = arguments["filter"] { filter } else { [:] }
        let matching = submissions.sorted { $0.sendAt < $1.sendAt }.filter { submission in
            filter.allSatisfy { key, value in
                switch key {
                case "emailIds": DemoTransport.strings(value).contains(submission.emailId)
                case "identityIds": DemoTransport.strings(value).contains(submission.identityId)
                case "threadIds": DemoTransport.strings(value).contains(submission.threadId ?? "")
                case "undoStatus": value == "pending"
                case "before": DemoMessages.date(value).map { submission.sendAt < $0 } ?? true
                case "after": DemoMessages.date(value).map { submission.sendAt >= $0 } ?? true
                default: true
                }
            }
        }
        return [
            "accountId": .string(DemoTransport.accountId), "queryState": .string(String(submissionState)),
            "canCalculateChanges": false, "position": 0, "total": .number(Double(matching.count)),
            "ids": .array(matching.map { .string($0.id) }),
        ]
    }

    /// `EmailSubmission/set` (RFC 8621 §7.5), with the `Email/set` that its `onSuccess…` arguments make answered
    /// right after it under the same call id.
    mutating func setSubmissions(
        _ arguments: Object, context: inout DemoTransport.RequestContext, now: Date
    ) -> [DemoTransport.Answer] {
        if let type = nextSubmissionMethodError {
            nextSubmissionMethodError = nil
            return [.error(type)]
        }
        let creates: Object = if case .object(let creates)? = arguments["create"] { creates } else { [:] }
        let updates: Object = if case .object(let updates)? = arguments["update"] { updates } else { [:] }
        let destroys = DemoTransport.strings(arguments["destroy"])
        let onSuccessUpdate: Object? = if case .object(let patches)? = arguments["onSuccessUpdateEmail"] {
            patches
        } else {
            nil
        }
        let onSuccessDestroy: [String]? = if case .array? = arguments["onSuccessDestroyEmail"] {
            DemoTransport.strings(arguments["onSuccessDestroyEmail"])
        } else {
            nil
        }
        if onSuccessUpdate != nil || onSuccessDestroy != nil {
            // As Cyrus: changing emails needs the mail capability, and only submissions of this call can be named.
            guard context.using.contains(Capability.mail) else {
                return [.error("invalidArguments", description: "onSuccess… arguments need \(Capability.mail)")]
            }
            let unknown = (Array((onSuccessUpdate ?? [:]).keys) + (onSuccessDestroy ?? [])).filter { key in
                key.hasPrefix("#")
                    ? creates[String(key.dropFirst())] == nil : updates[key] == nil && !destroys.contains(key)
            }
            guard unknown.isEmpty else {
                return [.error("invalidArguments", description: "No such submission in this call: \(unknown.sorted())")]
            }
        }

        var result: Object = [
            "accountId": .string(DemoTransport.accountId), "oldState": .string(String(submissionState)),
        ]
        var emailOfSubmission: [String: String] = [:]
        var changed = false
        if !creates.isEmpty {
            var created: Object = [:]
            var notCreated: Object = [:]
            for (creationId, value) in creates.sorted(by: { $0.key < $1.key }) {
                switch createSubmission(value, context: context, now: now) {
                case .refused(let error):
                    notCreated[creationId] = error
                case .accepted(let submission, let isHeld):
                    context.createdIDs[creationId] = submission.id
                    emailOfSubmission[submission.id] = submission.emailId
                    var answer: Object = [
                        "id": .string(submission.id), "undoStatus": isHeld ? "pending" : "final",
                        "sendAt": .string(submission.sendAt.formatted(.iso8601)),
                    ]
                    if let threadId = submission.threadId { answer["threadId"] = .string(threadId) }
                    created[creationId] = .object(answer)
                    if isHeld { submissions.append(submission) } else { release(submission, now: now) }
                    changed = true
                }
            }
            result["created"] = .object(created)
            if !notCreated.isEmpty { result["notCreated"] = .object(notCreated) }
        }
        if !updates.isEmpty {
            var updated: Object = [:]
            var notUpdated: Object = [:]
            for (id, patch) in updates {
                guard case .object(let patch) = patch, patch == ["undoStatus": "canceled"] else {
                    notUpdated[id] = DemoTransport.setError(SetError.invalidProperties, properties: ["undoStatus"])
                    continue
                }
                // Released (and so deleted) or never there: as with Fastmail, both look the same.
                guard let index = submissions.firstIndex(where: { $0.id == id }) else {
                    notUpdated[id] = DemoTransport.setError(SetError.notFound)
                    continue
                }
                emailOfSubmission[id] = submissions.remove(at: index).emailId
                updated[id] = .null
                changed = true
            }
            result["updated"] = .object(updated)
            if !notUpdated.isEmpty { result["notUpdated"] = .object(notUpdated) }
        }
        if !destroys.isEmpty {
            let refused = DemoTransport.setError(
                SetError.forbidden, description: "Submissions can't be destroyed here.")
            result["destroyed"] = []
            result["notDestroyed"] = .object(Dictionary(uniqueKeysWithValues: destroys.map { ($0, refused) }))
        }
        if changed { recordSubmissionChange() }
        result["newState"] = .string(String(submissionState))

        let answer = DemoTransport.Answer(name: "EmailSubmission/set", arguments: result)
        guard onSuccessUpdate != nil || onSuccessDestroy != nil else { return [answer] }
        return [answer, applyOnSuccess(update: onSuccessUpdate, destroy: onSuccessDestroy,
                                       emailOfSubmission: emailOfSubmission, context: context)]
    }

    /// The implicit `Email/set`, for the submissions of this call that succeeded.
    private mutating func applyOnSuccess(
        update: Object?, destroy: [String]?, emailOfSubmission: [String: String],
        context: DemoTransport.RequestContext
    ) -> DemoTransport.Answer {
        func emailID(_ key: String) -> String? {
            let submissionID = key.hasPrefix("#") ? context.createdIDs[String(key.dropFirst())] : key
            return submissionID.flatMap { emailOfSubmission[$0] }
        }
        var result: Object = ["accountId": .string(DemoTransport.accountId), "oldState": .string(String(state))]
        if let update {
            var updated: Object = [:]
            var notUpdated: Object = [:]
            for (key, patch) in update {
                guard let id = emailID(key) else { continue }
                guard case .object(let patch) = patch, let index = emails.firstIndex(where: { $0["id"] == .string(id) })
                else {
                    notUpdated[id] = DemoTransport.setError(SetError.notFound)
                    continue
                }
                DemoTransport.apply(patch, to: &emails[index])
                record(id, .updated)
                updated[id] = .null
            }
            result["updated"] = .object(updated)
            if !notUpdated.isEmpty { result["notUpdated"] = .object(notUpdated) }
        }
        if let destroy {
            var destroyed: [JSONValue] = []
            var notDestroyed: Object = [:]
            for key in destroy {
                guard let id = emailID(key) else { continue }
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
        return DemoTransport.Answer(name: "Email/set", arguments: result)
    }

    enum SubmissionCreation {
        case accepted(Submission, isHeld: Bool)
        case refused(JSONValue)
    }

    /// Checks a submission the way Fastmail does as far as it's known (RFC 8621 §7.5, Cyrus).
    private mutating func createSubmission(
        _ value: JSONValue, context: DemoTransport.RequestContext, now: Date
    ) -> SubmissionCreation {
        func refused(_ type: String, properties: [String]? = nil, description: String? = nil) -> SubmissionCreation {
            .refused(DemoTransport.setError(type, description: description, properties: properties))
        }
        if let rejection = nextSubmissionRejection {
            nextSubmissionRejection = nil
            return .refused(Self.json(rejection))
        }
        guard case .object(let create) = value else { return refused(SetError.invalidProperties) }
        let identityId = DemoTransport.string(create["identityId"])
        guard let identity = identities.first(where: { DemoTransport.string($0["id"]) == identityId }) else {
            return refused(SetError.invalidProperties, properties: ["identityId"])
        }
        var emailId = DemoTransport.string(create["emailId"])
        if emailId.hasPrefix("#") {
            guard let created = context.createdIDs[String(emailId.dropFirst())] else {
                return refused(SetError.invalidProperties, properties: ["emailId"])
            }
            emailId = created
        }

        var hold: Int?
        var given: (mailFrom: String, rcptTo: [String], envelope: JSONValue)?
        if case .object(let envelope)? = create["envelope"] {
            guard case .object(let mailFrom)? = envelope["mailFrom"], case .string(let sender)? = mailFrom["email"],
                  case .array(let recipients)? = envelope["rcptTo"]
            else { return refused(SetError.invalidProperties, properties: ["envelope"]) }
            let rcptTo = recipients.compactMap { recipient -> String? in
                guard case .object(let recipient) = recipient else { return nil }
                return DemoTransport.string(recipient["email"]).isEmpty ? nil : DemoTransport.string(recipient["email"])
            }
            guard rcptTo.count == recipients.count else {
                return refused(SetError.invalidProperties, properties: ["envelope/rcptTo"])
            }
            if case .object(let parameters)? = mailFrom["parameters"], let holdFor = parameters["HOLDFOR"] {
                if rejectsHoldFor { return refused(SetError.invalidProperties, properties: ["envelope"]) }
                // RFC 4865: a number of seconds, at most 99999999, sent as a string of digits.
                guard case .string(let digits) = holdFor, !digits.isEmpty,
                      digits.allSatisfy({ ("0"..."9").contains($0) }), let seconds = Int(digits), seconds <= 99_999_999
                else {
                    return refused(SetError.invalidProperties, properties: ["envelope/mailFrom/parameters/HOLDFOR"])
                }
                hold = seconds
            }
            given = (sender, rcptTo, .object(envelope))
        }

        guard let email = email(emailId) else { return refused(SetError.emailNotFound) }
        func addresses(_ property: String) -> [String] {
            DemoMessages.objects(email[property]).map { DemoTransport.string($0["email"]) }
        }
        let from = addresses("from").first ?? ""
        let mailFrom = given?.mailFrom ?? addresses("sender").first ?? from
        let rcptTo = given?.rcptTo ?? (addresses("to") + addresses("cc") + addresses("bcc"))
            .reduce(into: [String]()) { list, address in
                if !list.contains(where: { $0.lowercased() == address.lowercased() }) { list.append(address) }
            }
        guard !rcptTo.isEmpty else { return refused(SetError.noRecipients) }
        let invalid = rcptTo.filter { !Self.isValidAddress($0) }
        guard invalid.isEmpty else {
            return .refused(.object([
                "type": .string(SetError.invalidRecipients),
                "invalidRecipients": .array(invalid.map(JSONValue.string)),
            ]))
        }
        guard mayUse(identity, toSendFrom: from) else {
            return refused(SetError.forbiddenFrom, description: "You can't send from \(from) with this identity.")
        }
        guard mailFrom.lowercased() == from.lowercased() else {
            return refused(SetError.forbiddenMailFrom, description: "The envelope must be from \(from).")
        }
        let envelope = given?.envelope ?? [
            "mailFrom": ["email": .string(mailFrom), "parameters": .null],
            "rcptTo": .array(rcptTo.map { ["email": .string($0), "parameters": .null] }),
        ]
        let threadId = DemoTransport.string(email["threadId"])
        let submission = Submission(
            id: makeID("S"), identityId: identityId, emailId: emailId, threadId: threadId.isEmpty ? nil : threadId,
            envelope: envelope, mailFrom: mailFrom, rcptTo: rcptTo,
            sendAt: now.addingTimeInterval(TimeInterval(hold ?? 0)), email: email)
        return .accepted(submission, isHeld: hold != nil)
    }

    /// The identity's own address, or one at its domain for a wildcard identity; and, unless the server is
    /// strict about it, any masked address of the account.
    private func mayUse(_ identity: Object, toSendFrom address: String) -> Bool {
        if Identity(id: "", email: DemoTransport.string(identity["email"])).matches(address) { return true }
        return !requiresIdentityForMaskedFrom
            && maskedEmails.contains { DemoTransport.string($0["email"]).lowercased() == address.lowercased() }
    }

    private static func isValidAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !address.contains(where: \.isWhitespace)
    }

    mutating func releaseDue(now: Date) {
        let due = submissions.filter { $0.sendAt.addingTimeInterval(releaseDelay) <= now }
            .sorted { $0.sendAt < $1.sendAt }
        guard !due.isEmpty else { return }
        submissions.removeAll { submission in due.contains { $0.id == submission.id } }
        for submission in due { release(submission, now: now) }
        recordSubmissionChange()
    }

    /// Sends the message: it is recorded in `sentMessages`, and a copy arrives in the inbox if it went to the
    /// account itself.
    private mutating func release(_ submission: Submission, now: Date) {
        let email = submission.email
        sentMessages.append(DemoSentMessage(
            submissionId: submission.id, emailId: submission.emailId, identityId: submission.identityId,
            from: DemoMessages.objects(email["from"]).first.map { DemoTransport.string($0["email"]) } ?? "",
            mailFrom: submission.mailFrom, rcptTo: submission.rcptTo, subject: DemoTransport.string(email["subject"]),
            messageId: DemoTransport.strings(email["messageId"]).first, sentAt: now))
        guard submission.rcptTo.contains(where: { $0.lowercased() == DemoData.me }) else { return }
        let id = makeID("M")
        var copy = email
        copy["id"] = .string(id)
        copy["blobId"] = .string("\(id)-blob")
        copy["mailboxIds"] = ["inbox": true]
        copy["keywords"] = [:]
        copy["receivedAt"] = .string(now.formatted(.iso8601))
        // Delivery removes Bcc (RFC 8621 §7.5).
        copy["bcc"] = .null
        emails.append(copy)
        headers[id] = [DemoHeader("X-Delivered-To", DemoData.me)]
        record(id, .created, isDelivery: true)
    }

    private static func object(_ submission: Submission) -> Object {
        [
            "id": .string(submission.id), "identityId": .string(submission.identityId),
            "emailId": .string(submission.emailId), "threadId": submission.threadId.map(JSONValue.string) ?? .null,
            "envelope": submission.envelope, "sendAt": .string(submission.sendAt.formatted(.iso8601)),
            "undoStatus": "pending", "deliveryStatus": .null, "dsnBlobIds": [], "mdnBlobIds": [],
        ]
    }

    /// `objects` with the asked-for properties, those of `ids` or all (RFC 8620 §5.1).
    private static func select(
        _ objects: [Object], ids: JSONValue?, properties: JSONValue?
    ) -> (list: [JSONValue], notFound: [JSONValue]) {
        let properties = DemoTransport.strings(properties)
        func shown(_ object: Object) -> JSONValue {
            .object(properties.isEmpty ? object : object.filter { $0.key == "id" || properties.contains($0.key) })
        }
        guard case .array? = ids else { return (objects.map(shown), []) }
        var list: [JSONValue] = []
        var notFound: [JSONValue] = []
        for id in DemoTransport.strings(ids) {
            if let object = objects.first(where: { $0["id"] == .string(id) }) { list.append(shown(object)) } else {
                notFound.append(.string(id))
            }
        }
        return (list, notFound)
    }

    private static func json(_ error: SetError) -> JSONValue {
        let data = (try? JSONEncoder().encode(EncodableSetError(error))) ?? Data()
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object(["type": .string(error.type)])
    }
}

/// `SetError` is only `Decodable`; this writes one the way a server would.
private struct EncodableSetError: Encodable {
    let error: SetError

    init(_ error: SetError) {
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case type, description, properties, notFound, maxSize, maxRecipients, invalidRecipients
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(error.type, forKey: .type)
        try container.encodeIfPresent(error.description, forKey: .description)
        try container.encodeIfPresent(error.properties, forKey: .properties)
        try container.encodeIfPresent(error.notFound, forKey: .notFound)
        try container.encodeIfPresent(error.maxSize, forKey: .maxSize)
        try container.encodeIfPresent(error.maxRecipients, forKey: .maxRecipients)
        try container.encodeIfPresent(error.invalidRecipients, forKey: .invalidRecipients)
    }
}
