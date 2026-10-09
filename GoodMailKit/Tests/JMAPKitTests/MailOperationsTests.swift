import Foundation
import Testing
@testable import JMAPKit

struct MailOperationsTests {
    let transport = StubTransport()

    func makeClient() -> JMAPClient {
        JMAPClient(token: "secret", transport: transport, retryDelay: { _ in .zero })
    }

    @Test func assemblesThreadsInQueryOrder() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "thread_list")

        let page = try await makeClient().threads(matching: .condition(.init(inMailbox: "mb1")), limit: 2)

        #expect(page.total == 12)
        #expect(page.threads.map(\.id) == ["t1", "t2"])
        let lunch = try #require(page.threads.first)
        #expect(lunch.emails.map(\.id) == ["e1", "e2", "e3"])
        #expect(lunch.anchor?.subject == "Re: Lunch")
        #expect(lunch.isUnread)
        #expect(lunch.isFlagged)
        #expect(lunch.hasAttachment)
        #expect(!page.threads[1].isUnread)

        guard case .object(let body)? = transport.requests.last?.jsonBody,
              case .array(let calls)? = body["methodCalls"], calls.count == 4,
              case .array(let query) = calls[0], case .array(let threads) = calls[2], case .array(let emails) = calls[3],
              case .object(let queryArgs) = query[1], case .object(let threadArgs) = threads[1],
              case .object(let emailArgs) = emails[1]
        else { Issue.record("Unexpected request shape"); return }

        #expect(queryArgs["collapseThreads"] == true)
        #expect(queryArgs["sort"] == [["property": "receivedAt", "isAscending": false]])
        #expect(threadArgs["#ids"] == ["resultOf": "c1", "name": "Email/get", "path": "/list/*/threadId"])
        #expect(emailArgs["#ids"] == ["resultOf": "c2", "name": "Thread/get", "path": "/list/*/emailIds"])
    }

    @Test func fetchesThreadBodiesInThreadOrder() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s1", "methodResponses": [
              ["Thread/get", {"accountId": "u1234", "state": "t1", "notFound": [],
                "list": [{"id": "t1", "emailIds": ["e1", "e2"]}]}, "c0"],
              ["Email/get", {"accountId": "u1234", "state": "e1", "notFound": [], "list": [
                {"id": "e2", "htmlBody": [{"partId": "1", "type": "text/plain"}],
                 "bodyValues": {"1": {"value": "Second", "isEncodingProblem": false, "isTruncated": false}}},
                {"id": "e1", "htmlBody": [{"partId": "2", "type": "text/html"}],
                 "bodyValues": {"2": {"value": "<p>First</p>", "isEncodingProblem": false, "isTruncated": false}}}
              ]}, "c1"]]}
            """.utf8)))

        let emails = try await makeClient().emails(inThread: "t1")

        #expect(emails.map(\.id) == ["e1", "e2"])
        #expect(emails[0].bodyValues?["2"]?.value == "<p>First</p>")
        guard case .object(let body)? = transport.requests.last?.jsonBody,
              case .array(let calls)? = body["methodCalls"], case .array(let get) = calls[1],
              case .object(let args) = get[1]
        else { Issue.record("Unexpected request shape"); return }
        #expect(args["fetchHTMLBodyValues"] == true)
    }

    @Test func updateEmailsSendsPatchesAndReturnsRejections() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s1", "methodResponses": [["Email/set",
              {"accountId": "u1234", "newState": "e2", "updated": {"e1": null},
               "notUpdated": {"e2": {"type": "notFound"}}}, "c0"]]}
            """.utf8)))

        let rejected = try await makeClient().updateEmails([
            "e1": .setKeyword(.seen, true),
            "e2": .move(from: "mb1", to: "arch"),
        ])

        #expect(rejected == ["e2": SetError(type: SetError.notFound, description: nil, properties: nil)])

        guard case .object(let body)? = transport.requests.last?.jsonBody,
              case .array(let calls)? = body["methodCalls"], case .array(let call) = calls[0]
        else { Issue.record("Unexpected request shape"); return }
        #expect(call[0] == "Email/set")
        #expect(call[1] == [
            "accountId": "u1234",
            "update": [
                "e1": ["keywords/$seen": true],
                "e2": ["mailboxIds/arch": true, "mailboxIds/mb1": nil],
            ],
        ])
    }

    @Test func updateEmailsReportsNothingWhenAllSucceed() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s1", "methodResponses": [["Email/set",
              {"accountId": "u1234", "newState": "e2", "updated": {"e1": null}}, "c0"]]}
            """.utf8)))

        #expect(try await makeClient().updateEmails(["e1": .setKeyword(.seen, true)]).isEmpty)
    }

    @Test func updateEmailsThrowsMethodErrors() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s1", "methodResponses": [["error", {"type": "invalidArguments"}, "c0"]]}
            """.utf8)))

        await #expect(throws: JMAPError.method(MethodError(type: "invalidArguments", description: nil))) {
            try await makeClient().updateEmails(["e1": .setKeyword(.seen, true)])
        }
    }

    @Test func updateEmailsWithNothingToDoSkipsTheNetwork() async throws {
        #expect(try await makeClient().updateEmails([:]).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func patchesApplyLocally() throws {
        let email = try JMAPCoding.makeDecoder().decode(Email.self, from: Data("""
            {"id": "e1", "mailboxIds": {"inbox": true}, "keywords": {"$seen": true}}
            """.utf8))

        #expect(email.applying(.setKeyword(.flagged, true)).has(.flagged))
        #expect(!email.applying(.setKeyword(.seen, false)).has(.seen))
        #expect(email.applying(.move(from: "inbox", to: "arch")).mailboxIds == ["arch": true])
        #expect(email.applying(.move(to: "label")).mailboxIds == ["inbox": true, "label": true])
        #expect(email.applying(.moveExclusively(to: "trash")).mailboxIds == ["trash": true])
    }

    static let mergeablePatches: [PatchObject] = [
        .setKeyword(.seen, true),
        .setKeyword(.seen, false),
        .setKeyword(.flagged, true),
        .move(from: "inbox", to: "arch"),
        .move(from: "arch", to: "inbox"),
        .move(to: "label"),
        ["mailboxIds/label": nil],
        .moveExclusively(to: "trash"),
        ["mailboxIds": ["arch": true, "label": true]],
        ["keywords": ["$draft": true]],
        ["keywords": [:]],
        ["keywords/a~1b~0c": true],
        ["keywords/$seen": true, "mailboxIds/inbox": nil, "mailboxIds/arch": true],
    ]

    @Test(arguments: mergeablePatches)
    func mergedPatchesApplyLikeSuccessivePatches(first: PatchObject) throws {
        let email = try JMAPCoding.makeDecoder().decode(Email.self, from: Data("""
            {"id": "e1", "mailboxIds": {"inbox": true, "label": true}, "keywords": {"$seen": true, "x": true}}
            """.utf8))

        for second in Self.mergeablePatches {
            for third in Self.mergeablePatches {
                let merged = first.merging(second).merging(third)
                #expect(email.applying(merged) == email.applying(first).applying(second).applying(third),
                    "\(first) + \(second) + \(third) -> \(merged)")
                #expect(!merged.keys.contains { path in merged.keys.contains { path.hasPrefix($0 + "/") } },
                    "\(merged) sets a property and a path inside it")
            }
        }
    }

    @Test func mergingFoldsPathsIntoEarlierValues() {
        #expect(PatchObject.moveExclusively(to: "trash").merging(.move(from: "trash", to: "inbox"))
            == ["mailboxIds": ["inbox": true]])
        #expect(PatchObject.setKeyword(.seen, true).merging(["keywords": ["x": true]]) == ["keywords": ["x": true]])
        #expect(PatchObject.setKeyword(.flagged, true).merging(.setKeyword(.flagged, false))
            == ["keywords/$flagged": nil])
        #expect((["subject": "a"] as PatchObject).merging(["keywords/$seen": true])
            == ["subject": "a", "keywords/$seen": true])
    }

    @Test func mergingHandlesNestedAndEscapedPaths() {
        let earlier: PatchObject = ["header:X": ["a/b": ["c": 1]], "other/x~1y/z": 1]
        #expect(earlier.merging(["header:X/a~1b/d": 2, "other/x~1y": 3])
            == ["header:X": ["a/b": ["c": 1, "d": 2]], "other/x~1y": 3])
        #expect(earlier.merging(["header:X/a~1b/c": nil]) == ["header:X": ["a/b": [:]], "other/x~1y/z": 1])
    }

    @Test func temporaryErrorsAreRetryable() {
        #expect(JMAPError.transport("offline").isTemporary)
        #expect(JMAPError.rateLimited.isTemporary)
        #expect(JMAPError.http(status: 503, problemType: nil).isTemporary)
        #expect(JMAPError.http(status: 408, problemType: nil).isTemporary)
        #expect(JMAPError.http(status: 429, problemType: nil).isTemporary)
        #expect(JMAPError.http(status: 400, problemType: JMAPError.limitProblemType).isTemporary)
        #expect(JMAPError.method(MethodError(type: MethodError.serverUnavailable, description: nil)).isTemporary)
        #expect(!JMAPError.http(status: 400, problemType: nil).isTemporary)
        #expect(!JMAPError.unauthorized.isTemporary)
        #expect(!JMAPError.decoding("bad").isTemporary)
        #expect(!JMAPError.method(MethodError(type: "invalidArguments", description: nil)).isTemporary)
        #expect(!JMAPError.method(MethodError(type: "serverFail", description: nil)).isTemporary)
    }

    @Test func patchPathsEscapeJSONPointerTokens() {
        let patch = PatchObject.setKeyword(Email.Keyword(rawValue: "a/b~c"), true)
        #expect(patch == ["keywords/a~1b~0c": true])
    }

    @Test func downloadsBlobWithAuthorization() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data([0x89, 0x50])))

        let data = try await makeClient().download(blobId: "b1", type: "image/png", name: "logo.png")

        #expect(data == Data([0x89, 0x50]))
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString
            == "https://www.fastmailusercontent.com/jmap/download/u1234/b1/logo.png?type=image%2Fpng")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func errorsHaveReadableDescriptions() {
        #expect(JMAPError.unauthorized.localizedDescription == "Fastmail no longer accepts this API token.")
        #expect(SetError(type: "notFound", description: nil, properties: nil).localizedDescription
            == "Fastmail couldn't apply the change: notFound.")
    }
}
