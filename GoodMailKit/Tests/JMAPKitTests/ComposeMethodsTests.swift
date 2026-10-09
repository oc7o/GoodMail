import Foundation
import Testing
@testable import JMAPKit

/// The calls for drafts, sending, identities and list headers, against the wire formats of plan §3.9.
struct ComposeMethodsTests {
    let transport = StubTransport()
    let mailboxes = MailboxRoles(drafts: "mb-drafts", sent: "mb-sent")
    /// 2026-10-09T14:03:00Z
    let sentAt = Date(timeIntervalSince1970: 1_791_554_580)

    func makeClient() -> JMAPClient {
        JMAPClient(token: "secret", transport: transport, retryDelay: { _ in .zero })
    }

    /// Answers the next request with the session, then with these method responses.
    func respond(_ methodResponses: String) {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data(#"{"sessionState": "s1", "methodResponses": \#(methodResponses)}"#.utf8)))
    }

    var lastRequest: JSONValue? {
        transport.requests.last?.jsonBody
    }

    func lastCall(_ index: Int = 0) -> JSONValue? {
        guard case .object(let body)? = lastRequest, case .array(let calls)? = body["methodCalls"],
              calls.indices.contains(index)
        else { return nil }
        return calls[index]
    }

    func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JMAPCoding.makeEncoder().encode(value))
    }

    func draft(body: (structure: EmailBodyPartCreate, values: [String: EmailBodyValueCreate])? = nil) -> EmailCreate {
        let body = body ?? EmailCreate.body(text: "See you", html: "<div>See you</div>", inline: [], attachments: [])
        return EmailCreate(
            mailboxIds: ["mb-drafts": true], keywords: ["$draft": true, "$seen": true],
            messageId: ["0f9c2e7a@fastmail.com"], inReplyTo: ["e3@demo"], references: ["e1@demo", "e3@demo"],
            from: [EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")],
            to: [EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")],
            subject: "Re: Trip to Lisbon", sentAt: sentAt, bodyStructure: body.structure, bodyValues: body.values)
    }

    let textPart: JSONValue = ["partId": "text", "type": "text/plain"]
    let htmlPart: JSONValue = ["partId": "html", "type": "text/html"]
    let logo = EmailBodyPartCreate.blob("Glogo", type: "image/png", name: "logo.png", disposition: "inline", cid: "logo@x")
    let invoice = EmailBodyPartCreate.blob("Ginvoice", type: "application/pdf", name: "Invoice.pdf", disposition: "attachment")

    // MARK: Body structure

    @Test func textAndHTMLMakeAnAlternative() throws {
        let body = EmailCreate.body(text: "Hi", html: "<div>Hi</div>", inline: [], attachments: [])

        #expect(try json(body.structure) == ["type": "multipart/alternative", "subParts": [textPart, htmlPart]])
        #expect(body.values == ["text": .init(value: "Hi"), "html": .init(value: "<div>Hi</div>")])
    }

    @Test func inlineImagesAreRelatedToTheHTML() throws {
        let body = EmailCreate.body(text: "Hi", html: #"<img src="cid:logo@x">"#, inline: [logo], attachments: [])

        #expect(try json(body.structure) == ["type": "multipart/alternative", "subParts": [
            textPart,
            ["type": "multipart/related", "subParts": [
                htmlPart,
                ["blobId": "Glogo", "type": "image/png", "name": "logo.png", "disposition": "inline", "cid": "logo@x"],
            ]],
        ]])
    }

    @Test func attachmentsWrapTheMessageInAMixedPart() throws {
        let attached = EmailCreate.body(text: "Hi", html: "<div>Hi</div>", inline: [], attachments: [invoice])
        let everything = EmailCreate.body(text: "Hi", html: "<div>Hi</div>", inline: [logo], attachments: [invoice])
        let pdf: JSONValue = ["blobId": "Ginvoice", "type": "application/pdf", "name": "Invoice.pdf", "disposition": "attachment"]

        #expect(try json(attached.structure) == ["type": "multipart/mixed", "subParts": [
            ["type": "multipart/alternative", "subParts": [textPart, htmlPart]], pdf,
        ]])
        #expect(try json(everything.structure) == ["type": "multipart/mixed", "subParts": [
            ["type": "multipart/alternative", "subParts": [textPart, ["type": "multipart/related", "subParts": [
                htmlPart,
                ["blobId": "Glogo", "type": "image/png", "name": "logo.png", "disposition": "inline", "cid": "logo@x"],
            ]]]],
            pdf,
        ]])
    }

    // MARK: Drafts

    @Test func draftIsSavedAndThePreviousVersionDestroyedInOneCall() async throws {
        respond(#"""
            [["Email/set", {"accountId": "u1234", "oldState": "1", "newState": "2",
              "created": {"d": {"id": "M2", "blobId": "G2", "threadId": "T1", "size": 512}}, "destroyed": ["M1"]}, "c0"]]
            """#)

        let result = try await makeClient().saveDraft(draft(), replacing: "M1")

        #expect(result == DraftSaveResult(createdID: "M2", createError: nil, destroyedPrevious: true, previousWasMissing: false))
        guard case .object(let body)? = lastRequest else { Issue.record("No request"); return }
        #expect(body["using"] == ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"])
        #expect(lastCall() == ["Email/set", [
            "accountId": "u1234",
            "create": ["d": [
                "mailboxIds": ["mb-drafts": true], "keywords": ["$draft": true, "$seen": true],
                "messageId": ["0f9c2e7a@fastmail.com"], "inReplyTo": ["e3@demo"], "references": ["e1@demo", "e3@demo"],
                "from": [["name": "Alex Berg", "email": "alex@fastmail.com"]],
                "to": [["name": "Maya Lindqvist", "email": "maya@lindqvist.example"]],
                "subject": "Re: Trip to Lisbon", "sentAt": "2026-10-09T14:03:00Z",
                "bodyStructure": ["type": "multipart/alternative", "subParts": [textPart, htmlPart]],
                "bodyValues": ["text": ["value": "See you"], "html": ["value": "<div>See you</div>"]],
            ]],
            "destroy": ["M1"],
        ], "c0"])
    }

    struct SaveCase: Sendable, CustomTestStringConvertible {
        let response: String
        let expected: DraftSaveResult
        let testDescription: String
    }

    static let invalid = SetError(type: SetError.invalidProperties, properties: ["bodyStructure"])
    static let saveCases = [
        SaveCase(
            response: #""created": {"d": {"id": "M2"}}, "destroyed": ["M1"]"#,
            expected: .init(createdID: "M2", createError: nil, destroyedPrevious: true, previousWasMissing: false),
            testDescription: "created, previous destroyed"),
        SaveCase(
            response: #""created": {"d": {"id": "M2"}}, "notDestroyed": {"M1": {"type": "notFound"}}"#,
            expected: .init(createdID: "M2", createError: nil, destroyedPrevious: true, previousWasMissing: true),
            testDescription: "created, previous missing"),
        SaveCase(
            response: #""notCreated": {"d": {"type": "invalidProperties", "properties": ["bodyStructure"]}}, "destroyed": ["M1"]"#,
            expected: .init(createdID: nil, createError: invalid, destroyedPrevious: true, previousWasMissing: false),
            testDescription: "not created, previous destroyed"),
        SaveCase(
            response: #""notCreated": {"d": {"type": "invalidProperties", "properties": ["bodyStructure"]}}, "notDestroyed": {"M1": {"type": "notFound"}}"#,
            expected: .init(createdID: nil, createError: invalid, destroyedPrevious: true, previousWasMissing: true),
            testDescription: "not created, previous missing"),
        SaveCase(
            response: #""created": {"d": {"id": "M2"}}, "notDestroyed": {"M1": {"type": "forbidden"}}"#,
            expected: .init(createdID: "M2", createError: nil, destroyedPrevious: false, previousWasMissing: false),
            testDescription: "created, previous kept"),
    ]

    @Test(arguments: saveCases)
    func draftSaveReportsWhatHappenedToBothVersions(_ saveCase: SaveCase) async throws {
        respond(#"[["Email/set", {"accountId": "u1234", "newState": "2", \#(saveCase.response)}, "c0"]]"#)

        #expect(try await makeClient().saveDraft(draft(), replacing: "M1") == saveCase.expected)
    }

    @Test func firstSaveDestroysNothing() async throws {
        respond(#"[["Email/set", {"accountId": "u1234", "newState": "2", "created": {"d": {"id": "M2"}}}, "c0"]]"#)

        let result = try await makeClient().saveDraft(draft(), replacing: nil)

        #expect(result == DraftSaveResult(createdID: "M2", createError: nil, destroyedPrevious: false, previousWasMissing: false))
        guard case .array(let call)? = lastCall(), case .object(let arguments) = call[1] else { return }
        #expect(arguments["destroy"] == nil)
    }

    // MARK: Sending

    var envelope: EmailSubmission.Envelope {
        EmailSubmission.Envelope(
            mailFrom: .init(email: "alex@fastmail.com", parameters: ["HOLDFOR": "15"]),
            rcptTo: [.init(email: "maya@lindqvist.example")])
    }

    @Test func emailAndSubmissionGoOutInOneRequest() async throws {
        respond(#"""
            [["Email/set", {"accountId": "u1234", "newState": "2",
               "created": {"m": {"id": "M9", "blobId": "G9", "threadId": "T1", "size": 900}}}, "c0"],
             ["EmailSubmission/set", {"accountId": "u1234", "newState": "s2",
               "created": {"s": {"id": "S4", "undoStatus": "pending", "sendAt": "2026-10-09T14:03:15Z"}}}, "c1"],
             ["Email/set", {"accountId": "u1234", "oldState": "2", "newState": "3", "updated": {"M9": null}}, "c1"]]
            """#)

        let result = try await makeClient().submit(
            draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)

        #expect(result == SubmissionResult(
            emailID: "M9",
            submission: EmailSubmission(
                id: "S4", identityId: "I1", emailId: "M9", threadId: "T1", envelope: envelope,
                sendAt: sentAt.addingTimeInterval(15), undoStatus: .pending),
            movedToSent: true))
        guard case .object(let body)? = lastRequest else { Issue.record("No request"); return }
        #expect(body["using"] == [
            "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission",
        ])
        guard case .array(let creation)? = lastCall(0), case .object(let creationArguments) = creation[1] else {
            Issue.record("No Email/set")
            return
        }
        #expect(creation[0] == "Email/set")
        #expect(creationArguments.keys.sorted() == ["accountId", "create"])
        #expect(lastCall(1) == ["EmailSubmission/set", [
            "accountId": "u1234",
            "create": ["s": [
                "identityId": "I1", "emailId": "#m",
                "envelope": [
                    "mailFrom": ["email": "alex@fastmail.com", "parameters": ["HOLDFOR": "15"]],
                    "rcptTo": [["email": "maya@lindqvist.example", "parameters": nil]],
                ],
            ]],
            "onSuccessUpdateEmail": ["#s": ["mailboxIds/mb-drafts": nil, "mailboxIds/mb-sent": true, "keywords/$draft": nil]],
        ], "c1"])
    }

    @Test func sendingIsNeverRepeatedAutomatically() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: 503, body: Data()))
        transport.enqueue(.init(body: Data(#"{"sessionState": "s1", "methodResponses": []}"#.utf8)))

        let error = await #expect(throws: JMAPError.self) {
            try await makeClient().submit(draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)
        }

        #expect(error == .http(status: 503, problemType: nil))
        #expect(error?.mayHaveReachedServer == true)
        #expect(transport.requests.count == 2)
    }

    @Test(arguments: [(503, JMAPError.http(status: 503, problemType: nil)), (429, .rateLimited)])
    func undoAndNewIdentitiesAreNeverRepeatedAutomatically(status: Int, expected: JMAPError) async throws {
        let client = makeClient()
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: status, body: Data(), headers: ["Retry-After": "0"]))
        await #expect(throws: expected) { try await client.cancelSubmission("S4", mailboxes: mailboxes) }

        transport.enqueue(.init(status: status, body: Data(), headers: ["Retry-After": "0"]))
        await #expect(throws: expected) { try await client.createIdentity(.init(email: "fjord.k3x9@fastmail.com")) }

        #expect(transport.requests.count == 3)
    }

    /// The error of a call whose session request is answered with `sessionReply`.
    func errorFetchingTheSession(
        _ sessionReply: StubTransport.Reply, _ operation: (JMAPClient) async throws -> Void
    ) async -> JMAPError? {
        transport.enqueue(sessionReply)
        do {
            try await operation(makeClient())
            return nil
        } catch {
            return error as? JMAPError
        }
    }

    /// Requests that must not run twice need the session first. When it can't be fetched, the request itself
    /// was certainly never sent, whatever the failure says about the session request.
    @Test(arguments: [
        (StubTransport.Reply.failing(.timedOut), JMAPError.connection(.timedOut, URLError(.timedOut).localizedDescription)),
        (.init(status: 500, body: Data()), .http(status: 500, problemType: nil)),
    ])
    func requestsThatMustNotRunTwiceAreUnsentWithoutASession(
        sessionReply: StubTransport.Reply, sessionError: JMAPError
    ) async throws {
        let errors = [
            await errorFetchingTheSession(sessionReply) {
                _ = try await $0.submit(draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)
            },
            await errorFetchingTheSession(sessionReply) { _ = try await $0.cancelSubmission("S4", mailboxes: mailboxes) },
            await errorFetchingTheSession(sessionReply) {
                _ = try await $0.createIdentity(.init(email: "fjord.k3x9@fastmail.com"))
            },
        ]

        #expect(errors == Array(repeating: .sessionUnavailable(sessionError), count: 3))
        #expect(errors.allSatisfy { $0?.mayHaveReachedServer == false && $0?.isTemporary == true })
        #expect(errors.first??.localizedDescription == sessionError.localizedDescription)
        #expect(transport.requests.count == 3)
    }

    @Test func otherCallsAndRefusedTokensGetTheSessionErrorAsItIs() async throws {
        let timeout = JMAPError.connection(.timedOut, URLError(.timedOut).localizedDescription)

        #expect(await errorFetchingTheSession(.failing(.timedOut)) { _ = try await $0.identities() } == timeout)
        #expect(await errorFetchingTheSession(.init(status: 401, body: Data())) {
            _ = try await $0.submit(draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)
        } == .unauthorized)
    }

    @Test func refusedSubmissionStillReportsTheCreatedEmail() async throws {
        respond(#"""
            [["Email/set", {"accountId": "u1234", "newState": "2", "created": {"m": {"id": "M9", "threadId": "T1"}}}, "c0"],
             ["EmailSubmission/set", {"accountId": "u1234", "newState": "s1",
               "notCreated": {"s": {"type": "forbiddenFrom", "description": "Not your address"}}}, "c1"],
             ["Email/set", {"accountId": "u1234", "oldState": "2", "newState": "2", "updated": {}}, "c1"]]
            """#)

        let result = try await makeClient().submit(draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)

        #expect(result == SubmissionResult(
            emailID: "M9",
            submissionError: SetError(type: SetError.forbiddenFrom, description: "Not your address")))
    }

    @Test func failedSubmissionCallStillReportsTheCreatedEmail() async throws {
        respond(#"""
            [["Email/set", {"accountId": "u1234", "newState": "2", "created": {"m": {"id": "M9"}}}, "c0"],
             ["error", {"type": "serverUnavailable"}, "c1"]]
            """#)

        let result = try await makeClient().submit(draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)

        #expect(result == SubmissionResult(
            emailID: "M9", submissionMethodError: MethodError(type: MethodError.serverUnavailable)))
    }

    @Test func refusedEmailIsReported() async throws {
        respond(#"""
            [["Email/set", {"accountId": "u1234", "newState": "1",
               "notCreated": {"m": {"type": "blobNotFound", "notFound": ["Gexpired"]}}}, "c0"],
             ["EmailSubmission/set", {"accountId": "u1234", "newState": "s1",
               "notCreated": {"s": {"type": "invalidProperties", "properties": ["emailId"]}}}, "c1"]]
            """#)

        let result = try await makeClient().submit(draft(), identityID: "I1", envelope: envelope, mailboxes: mailboxes)

        #expect(result.emailID == nil)
        #expect(result.emailError == SetError(type: SetError.blobNotFound, notFound: ["Gexpired"]))
        #expect(result.submissionError?.type == SetError.invalidProperties)
        #expect(!result.movedToSent)
    }

    @Test func emailSubmissionSetUsesMailAndCreationReferences() throws {
        var batch = Batch()
        batch.add(EmailSubmissionSet(
            accountId: "A", create: ["s": .init(identityId: "I", emailId: "#m", envelope: nil)],
            onSuccessUpdateEmail: ["#s": .setKeyword(.draft, false)], onSuccessDestroyEmail: ["#s"]))

        #expect(try json(batch) == [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"],
            "methodCalls": [["EmailSubmission/set", [
                "accountId": "A", "create": ["s": ["identityId": "I", "emailId": "#m"]],
                "onSuccessUpdateEmail": ["#s": ["keywords/$draft": nil]], "onSuccessDestroyEmail": ["#s"],
            ], "c0"]],
        ])
    }

    @Test func implicitEmailSetFollowsTheSubmission() throws {
        var batch = Batch()
        batch.add(EmailSet(accountId: "A"))
        let submission = batch.add(EmailSubmissionSet(accountId: "A"))
        func response(_ answers: String) throws -> BatchResponse {
            try JMAPCoding.makeDecoder().decode(BatchResponse.self, from: Data(#"""
                {"sessionState": "s1", "methodResponses": [["Email/set", {"accountId": "A", "newState": "1"}, "c0"], \#(answers)]}
                """#.utf8))
        }

        let applied = try response(#"""
            ["EmailSubmission/set", {"accountId": "A", "newState": "s2", "created": {"s": {"id": "S1"}}}, "c1"],
            ["Email/set", {"accountId": "A", "oldState": "1", "newState": "2", "updated": {"M1": null}}, "c1"]
            """#)
        #expect(try applied.get(submission).created?.keys.sorted() == ["s"])
        #expect(try applied.implicitEmailSet(submission)?.updated?.keys.sorted() == ["M1"])

        let failed = try response(#"""
            ["EmailSubmission/set", {"accountId": "A", "newState": "s2", "created": {"s": {"id": "S1"}}}, "c1"],
            ["error", {"type": "serverFail"}, "c1"]
            """#)
        #expect(try failed.get(submission).created?.keys.sorted() == ["s"])
        #expect(throws: JMAPError.method(MethodError(type: "serverFail"))) { try failed.implicitEmailSet(submission) }

        let refused = try response(#"["error", {"type": "forbidden"}, "c1"]"#)
        #expect(throws: JMAPError.method(MethodError(type: SetError.forbidden))) { try refused.get(submission) }
        #expect(try refused.implicitEmailSet(submission) == nil)

        let without = try response(#"["EmailSubmission/set", {"accountId": "A", "newState": "s2"}, "c1"]"#)
        #expect(try without.implicitEmailSet(submission) == nil)
    }

    // MARK: Undo

    @Test func cancellingMovesTheEmailBackToDrafts() async throws {
        respond(#"""
            [["EmailSubmission/set", {"accountId": "u1234", "newState": "s3", "updated": {"S4": null}}, "c0"],
             ["Email/set", {"accountId": "u1234", "newState": "4", "updated": {"M9": null}}, "c0"]]
            """#)

        #expect(try await makeClient().cancelSubmission("S4", mailboxes: mailboxes) == .canceled)
        guard case .object(let body)? = lastRequest else { Issue.record("No request"); return }
        #expect(body["using"] == [
            "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission",
        ])
        #expect(lastCall() == ["EmailSubmission/set", [
            "accountId": "u1234", "update": ["S4": ["undoStatus": "canceled"]],
            "onSuccessUpdateEmail": ["S4": ["mailboxIds/mb-sent": nil, "mailboxIds/mb-drafts": true, "keywords/$draft": true]],
        ], "c0"])
    }

    @Test(arguments: [
        ("notFound", SubmissionCancellation.alreadySent), ("cannotUnsend", .alreadySent),
        ("forbidden", .failed(SetError(type: SetError.forbidden))),
    ])
    func cancellingTooLateMeansItWasSent(type: String, expected: SubmissionCancellation) async throws {
        respond(#"""
            [["EmailSubmission/set", {"accountId": "u1234", "newState": "s3", "notUpdated": {"S4": {"type": "\#(type)"}}}, "c0"],
             ["Email/set", {"accountId": "u1234", "newState": "4", "updated": {}}, "c0"]]
            """#)

        #expect(try await makeClient().cancelSubmission("S4", mailboxes: mailboxes) == expected)
    }

    // MARK: Cleanup and lookups

    @Test func destroyingCountsMissingEmailsAsDestroyed() async throws {
        respond(#"""
            [["Email/set", {"accountId": "u1234", "newState": "5", "destroyed": ["M1"],
              "notDestroyed": {"M2": {"type": "notFound"}, "M3": {"type": "forbidden"}}}, "c0"]]
            """#)

        #expect(try await makeClient().destroyEmails(["M1", "M2", "M3"]) == ["M3": SetError(type: SetError.forbidden)])
        #expect(lastCall() == ["Email/set", ["accountId": "u1234", "destroy": ["M1", "M2", "M3"]], "c0"])
        #expect(try await makeClient().destroyEmails([]).isEmpty)
        #expect(transport.requests.count == 2)
    }

    @Test func messageIDIsLookedUpWithTheHeaderFilter() async throws {
        respond(#"""
            [["Email/query", {"accountId": "u1234", "queryState": "q", "canCalculateChanges": false, "position": 0,
              "ids": ["M1", "M2"]}, "c0"],
             ["Email/get", {"accountId": "u1234", "state": "5", "notFound": [], "list": [
              {"id": "M1", "mailboxIds": {"mb-drafts": true}, "keywords": {"$draft": true}, "messageId": ["abc@x"],
               "receivedAt": "2026-10-09T14:00:00Z"},
              {"id": "M2", "mailboxIds": {"mb-sent": true}, "keywords": {"$seen": true}, "messageId": ["abc@x"],
               "receivedAt": "2026-10-09T14:03:00Z"}]}, "c1"]]
            """#)

        let lookup = try await makeClient().emails(withMessageID: "abc@x")

        #expect(lookup.filterWorked)
        #expect(lookup.matches == [
            EmailCopy(id: "M1", mailboxIds: ["mb-drafts": true], keywords: ["$draft": true], messageId: ["abc@x"],
                      receivedAt: Date(timeIntervalSince1970: 1_791_554_400)),
            EmailCopy(id: "M2", mailboxIds: ["mb-sent": true], keywords: ["$seen": true], messageId: ["abc@x"],
                      receivedAt: sentAt),
        ])
        #expect(lookup.matches.map(\.isDraft) == [true, false])
        #expect(lastCall(0) == ["Email/query", [
            "accountId": "u1234", "filter": ["header": ["Message-ID", "abc@x"]], "limit": 50,
        ], "c0"])
        #expect(lastCall(1) == ["Email/get", [
            "accountId": "u1234", "#ids": ["resultOf": "c0", "name": "Email/query", "path": "/ids"],
            "properties": ["id", "mailboxIds", "keywords", "messageId", "receivedAt"],
        ], "c1"])
    }

    @Test func serverIgnoringTheHeaderFilterIsNoticed() async throws {
        respond(#"""
            [["Email/query", {"accountId": "u1234", "queryState": "q", "canCalculateChanges": false, "position": 0,
              "ids": ["M1", "M2", "M3"]}, "c0"],
             ["Email/get", {"accountId": "u1234", "state": "5", "notFound": [], "list": [
              {"id": "M1", "mailboxIds": {"inbox": true}, "keywords": {}, "messageId": ["other@x"]},
              {"id": "M2", "mailboxIds": {"mb-sent": true}, "keywords": {}, "messageId": ["abc@x"]},
              {"id": "M3", "mailboxIds": {"inbox": true}, "keywords": {}, "messageId": null}]}, "c1"]]
            """#)

        let lookup = try await makeClient().emails(withMessageID: "abc@x")

        #expect(!lookup.filterWorked)
        #expect(lookup.matches.map(\.id) == ["M2"])
    }

    @Test func recentEmailsAreAskedForByMailboxAndTime() async throws {
        respond(#"""
            [["Email/query", {"accountId": "u1234", "queryState": "q", "canCalculateChanges": false, "position": 0,
              "ids": ["M2", "M1"]}, "c0"],
             ["Email/get", {"accountId": "u1234", "state": "5", "notFound": [], "list": [
              {"id": "M1", "mailboxIds": {"mb-drafts": true}, "keywords": {"$draft": true}, "messageId": ["a@x"]},
              {"id": "M2", "mailboxIds": {"mb-sent": true}, "keywords": {}, "messageId": ["b@x"]}]}, "c1"]]
            """#)

        let copies = try await makeClient().recentEmails(inMailboxes: ["mb-drafts", "mb-sent"], after: sentAt, limit: 200)

        #expect(copies.map(\.id) == ["M2", "M1"])
        #expect(lastCall(0) == ["Email/query", [
            "accountId": "u1234",
            "filter": ["operator": "AND", "conditions": [
                ["operator": "OR", "conditions": [["inMailbox": "mb-drafts"], ["inMailbox": "mb-sent"]]],
                ["after": "2026-10-09T14:03:00Z"],
            ]],
            "sort": [["property": "receivedAt", "isAscending": false]], "limit": 200,
        ], "c0"])
    }

    @Test func submissionsOfEmailsAreQueriedThenFetched() async throws {
        respond(#"""
            [["EmailSubmission/query", {"accountId": "u1234", "queryState": "s3", "canCalculateChanges": false,
              "position": 0, "ids": ["S4"]}, "c0"],
             ["EmailSubmission/get", {"accountId": "u1234", "state": "s3", "notFound": [], "list": [
              {"id": "S4", "emailId": "M9", "undoStatus": "pending", "sendAt": "2026-10-09T14:03:15Z"}]}, "c1"]]
            """#)

        let found = try await makeClient().submissions(forEmailIDs: ["M9", "M8"])

        #expect(found == [EmailSubmission(id: "S4", emailId: "M9", sendAt: sentAt.addingTimeInterval(15), undoStatus: .pending)])
        guard case .object(let body)? = lastRequest else { Issue.record("No request"); return }
        #expect(body["using"] == ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:submission"])
        #expect(lastCall(0) == ["EmailSubmission/query", ["accountId": "u1234", "filter": ["emailIds": ["M9", "M8"]]], "c0"])
        #expect(lastCall(1) == ["EmailSubmission/get", [
            "accountId": "u1234", "#ids": ["resultOf": "c0", "name": "EmailSubmission/query", "path": "/ids"],
            "properties": ["id", "emailId", "undoStatus", "sendAt"],
        ], "c1"])
        #expect(try await makeClient().submissions(forEmailIDs: []).isEmpty)
    }

    @Test func submissionsByIDReportWhichAreGone() async throws {
        respond(#"""
            [["EmailSubmission/get", {"accountId": "u1234", "state": "s3", "notFound": ["S3"], "list": [
              {"id": "S4", "identityId": "I1", "emailId": "M9", "threadId": "T1", "undoStatus": "pending",
               "sendAt": "2026-10-09T14:03:15Z", "deliveryStatus": null, "dsnBlobIds": [], "mdnBlobIds": [],
               "envelope": {"mailFrom": {"email": "alex@fastmail.com", "parameters": {"HOLDFOR": "15"}},
                            "rcptTo": [{"email": "maya@lindqvist.example", "parameters": null}]}}]}, "c0"]]
            """#)

        let (found, notFound) = try await makeClient().submissions(ids: ["S4", "S3"])

        #expect(found == [EmailSubmission(
            id: "S4", identityId: "I1", emailId: "M9", threadId: "T1", envelope: envelope,
            sendAt: sentAt.addingTimeInterval(15), undoStatus: .pending)])
        #expect(notFound == ["S3"])
    }

    @Test func emailsAreFetchedWithJustTheAskedForProperties() async throws {
        respond(#"""
            [["Email/get", {"accountId": "u1234", "state": "5", "notFound": ["M2"], "list": [
              {"id": "M1", "mailboxIds": {"mb-sent": true}, "keywords": {}}]}, "c0"]]
            """#)

        let emails = try await makeClient().emails(ids: ["M1", "M2"], properties: ["mailboxIds", "keywords"])

        #expect(emails.map(\.id) == ["M1"])
        #expect(emails.first?.mailboxIds == ["mb-sent": true])
        #expect(lastCall() == ["Email/get", ["accountId": "u1234", "ids": ["M1", "M2"], "properties": ["mailboxIds", "keywords"]], "c0"])
    }

    // MARK: Errors, session, identities

    @Test func setErrorsCarryTheirDetails() throws {
        let decoder = JMAPCoding.makeDecoder()
        func decode(_ json: String) throws -> SetError { try decoder.decode(SetError.self, from: Data(json.utf8)) }

        #expect(try decode(#"{"type": "blobNotFound", "notFound": ["G1", "G2"]}"#)
            == SetError(type: SetError.blobNotFound, notFound: ["G1", "G2"]))
        #expect(try decode(#"{"type": "tooLarge", "maxSize": 70000000}"#).maxSize == 70_000_000)
        #expect(try decode(#"{"type": "tooManyRecipients", "maxRecipients": 100}"#).maxRecipients == 100)
        #expect(try decode(#"{"type": "invalidRecipients", "invalidRecipients": ["a@b"], "extra": 1}"#).invalidRecipients
            == ["a@b"])
        #expect(try decode(#"{"type": "forbiddenToSend", "description": "Daily limit reached"}"#)
            == SetError(type: SetError.forbiddenToSend, description: "Daily limit reached"))
    }

    func fastmailSession(_ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> Session {
        guard case .object(var session) = try JSONDecoder().decode(JSONValue.self, from: Fixtures.data("session_fastmail"))
        else { throw JMAPError.decoding("fixture") }
        change(&session)
        return try JMAPCoding.makeDecoder().decode(Session.self, from: JSONEncoder().encode(JSONValue.object(session)))
    }

    @Test func sessionTellsTheLimitsAndWhetherItCanSend() throws {
        let session = try fastmailSession()

        #expect(session.coreCapabilities == CoreCapabilities(
            maxSizeUpload: 250_000_000, maxConcurrentUpload: 10, maxSizeRequest: 10_000_000, maxConcurrentRequests: 10,
            maxCallsInRequest: 50, maxObjectsInGet: 4096, maxObjectsInSet: 4096))
        #expect(session.mailCapabilities(accountId: "u1234")
            == MailAccountCapabilities(maxSizeAttachmentsPerEmail: 50_000_000, maxMailboxesPerEmail: 1000))
        #expect(session.submissionCapabilities(accountId: "u1234")
            == SubmissionAccountCapabilities(maxDelayedSend: 44_236_800, submissionExtensions: [:]))
        #expect(session.mailCapabilities(accountId: "other") == nil)
        #expect(session.canSubmit)
    }

    @Test func sessionWithoutSubmissionCantSend() throws {
        let readOnly = try fastmailSession { session in
            guard case .object(var accounts)? = session["accounts"], case .object(var account)? = accounts["u1234"]
            else { return }
            account["isReadOnly"] = true
            accounts["u1234"] = .object(account)
            session["accounts"] = .object(accounts)
        }
        let withoutScope = try fastmailSession { session in
            guard case .object(var capabilities)? = session["capabilities"],
                  case .object(var primary)? = session["primaryAccounts"]
            else { return }
            capabilities[Capability.submission] = nil
            primary[Capability.submission] = nil
            session["capabilities"] = .object(capabilities)
            session["primaryAccounts"] = .object(primary)
        }
        let withoutAccount = try fastmailSession { session in
            guard case .object(var primary)? = session["primaryAccounts"] else { return }
            primary[Capability.submission] = nil
            session["primaryAccounts"] = .object(primary)
        }

        #expect(!readOnly.canSubmit)
        #expect(!withoutScope.canSubmit)
        #expect(withoutScope.submissionCapabilities(accountId: "u1234") != nil)
        #expect(!withoutAccount.canSubmit)
    }

    @Test func sessionMissingCoreLimitsHasNone() throws {
        let session = try JMAPCoding.makeDecoder().decode(Session.self, from: Fixtures.data("session"))
        #expect(session.coreCapabilities == nil)
        #expect(session.canSubmit)
    }

    @Test func identitiesAreReadLeniently() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "identity_get")

        let identities = try await makeClient().identities()

        #expect(identities == [
            Identity(id: "I1", name: "Alex Berg", email: "user@fastmail.com", textSignature: "-- \nAlex",
                     htmlSignature: "<div>Alex</div>", mayDelete: false),
            Identity(id: "I2", name: "", email: "*@berg.example", replyTo: [EmailAddress(email: "replies@berg.example")],
                     bcc: [EmailAddress(name: "Archive", email: "archive@berg.example")], textSignature: "",
                     htmlSignature: "", mayDelete: true),
            Identity(id: "I3", name: "", email: "fjord.k3x9@fastmail.com", mayDelete: false),
        ])
        #expect(lastCall() == ["Identity/get", ["accountId": "u1234", "ids": nil], "c0"])
        guard case .object(let body)? = lastRequest else { return }
        #expect(body["using"] == ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:submission"])
    }

    @Test func identitiesSurviveBeingStored() throws {
        let identities = [
            Identity(id: "I1", name: "Alex Berg", email: "alex@fastmail.com", replyTo: [EmailAddress(email: "r@x.example")],
                     textSignature: "-- \nAlex", htmlSignature: "<div>Alex</div>"),
            Identity(id: "I2", email: "*@berg.example", mayDelete: true),
        ]
        let data = try JSONEncoder().encode(identities)
        #expect(try JSONDecoder().decode([Identity].self, from: data) == identities)
    }

    @Test(arguments: [
        ("alex@fastmail.com", "alex@fastmail.com", true), ("alex@fastmail.com", "Alex@FastMail.com", true),
        ("alex@fastmail.com", "alex@fastmail.co", false), ("*@berg.example", "shop@berg.example", true),
        ("*@berg.example", "SHOP@Berg.Example", true), ("*@berg.example", "a@sub.berg.example", false),
        ("*@berg.example", "@berg.example", false), ("*@berg.example", "berg.example", false),
        ("*@berg.example", "shop@berg.example.com", false),
    ])
    func identityCoversItsAddressOrDomain(identity: String, address: String, matches: Bool) {
        let identity = Identity(id: "I", email: identity)
        #expect(identity.matches(address) == matches)
        #expect(identity.isWildcard == identity.email.hasPrefix("*@"))
    }

    @Test func identityIsCreatedForAnAddress() async throws {
        respond(#"""
            [["Identity/set", {"accountId": "u1234", "oldState": "7", "newState": "8",
              "created": {"i": {"id": "I9", "mayDelete": true}}}, "c0"]]
            """#)

        let identity = try await makeClient().createIdentity(.init(email: "fjord.k3x9@fastmail.com"))

        #expect(identity == Identity(id: "I9", name: "", email: "fjord.k3x9@fastmail.com", mayDelete: true))
        #expect(lastCall() == ["Identity/set", [
            "accountId": "u1234", "create": ["i": ["email": "fjord.k3x9@fastmail.com", "name": ""]],
        ], "c0"])
    }

    @Test func refusedIdentityThrowsTheServersReason() async throws {
        respond(#"""
            [["Identity/set", {"accountId": "u1234", "newState": "7",
              "notCreated": {"i": {"type": "forbiddenFrom"}}}, "c0"]]
            """#)

        await #expect(throws: SetError(type: SetError.forbiddenFrom)) {
            try await makeClient().createIdentity(.init(email: "someone@else.example"))
        }
    }

    // MARK: Headers

    @Test func emailKnowsWhereItWasDeliveredTo() throws {
        let email = try JMAPCoding.makeDecoder().decode(Email.self, from: Data(#"""
            {"id": "e4", "header:X-Delivered-To:asAddresses:all": [[{"name": null, "email": "fjord.k3x9@fastmail.com"}],
                                                                   [{"name": null, "email": "alex@fastmail.com"}]],
             "header:List-Id:asText": "Fjord Outdoor News <news.fjord-outdoor.example>"}
            """#.utf8))

        #expect(email.deliveredToAddresses.map(\.email) == ["fjord.k3x9@fastmail.com", "alex@fastmail.com"])
        #expect(email.listId == "Fjord Outdoor News <news.fjord-outdoor.example>")
        #expect(Email.Properties.full.contains("header:X-Delivered-To:asAddresses:all"))
        #expect(Email.Properties.full.contains("header:List-Id:asText"))
        #expect(!Email.Properties.listing.contains("header:List-Id:asText"))
    }

    @Test func listHeadersAreReadInEveryInstance() async throws {
        respond(#"""
            [["Email/get", {"accountId": "u1234", "state": "5", "notFound": [], "list": [{"id": "e4",
              "header:List-Unsubscribe:asURLs:all": [["https://x.example/u", "mailto:u@x.example"], null],
              "header:List-Unsubscribe-Post:asText:all": ["List-Unsubscribe=One-Click"],
              "header:DKIM-Signature:all": [" v=1; d=x.example;\r\n\th=list-unsubscribe; b=AbCdEfGh123"],
              "header:Authentication-Results:asText:all": ["mx.messagingengine.com; dkim=pass header.b=AbCdEfGh"],
              "header:List-Id:asText": "X <x.example>",
              "headers": [
                {"name": "Received", "value": " from mail.x.example (mail.x.example [93.184.216.34])\r\n\tby mx.messagingengine.com"},
                {"name": "Authentication-Results", "value": " mx.messagingengine.com; dkim=pass header.b=AbCdEfGh"},
                {"name": "DKIM-Signature", "value": " v=1; d=x.example;\r\n\th=list-unsubscribe; b=AbCdEfGh123"},
                {"name": "list-unsubscribe", "value": " <https://x.example/u>, <mailto:u@x.example>"}]}]}, "c0"]]
            """#)

        let headers = try await makeClient().unsubscribeHeaders(emailID: "e4")

        #expect(headers == UnsubscribeHeaders(
            listUnsubscribe: [["https://x.example/u", "mailto:u@x.example"], []],
            listUnsubscribePost: ["List-Unsubscribe=One-Click"],
            dkimSignatures: [" v=1; d=x.example;\r\n\th=list-unsubscribe; b=AbCdEfGh123"],
            authenticationResults: ["mx.messagingengine.com; dkim=pass header.b=AbCdEfGh"], listId: "X <x.example>",
            headers: [
                .init(name: "Received", value: " from mail.x.example (mail.x.example [93.184.216.34])\r\n\tby mx.messagingengine.com"),
                .init(name: "Authentication-Results", value: " mx.messagingengine.com; dkim=pass header.b=AbCdEfGh"),
                .init(name: "DKIM-Signature", value: " v=1; d=x.example;\r\n\th=list-unsubscribe; b=AbCdEfGh123"),
                .init(name: "list-unsubscribe", value: " <https://x.example/u>, <mailto:u@x.example>"),
            ]))
        #expect(lastCall() == ["Email/get", ["accountId": "u1234", "ids": ["e4"], "properties": [
            "id", "header:List-Unsubscribe:asURLs:all", "header:List-Unsubscribe-Post:asText:all",
            "header:DKIM-Signature:all", "header:Authentication-Results:asText:all", "header:List-Id:asText", "headers",
        ]], "c0"])
    }

    @Test func listHeadersOfAMissingEmailAreNil() async throws {
        respond(#"[["Email/get", {"accountId": "u1234", "state": "5", "notFound": ["e99"], "list": []}, "c0"]]"#)

        #expect(try await makeClient().unsubscribeHeaders(emailID: "e99") == nil)
    }
}
