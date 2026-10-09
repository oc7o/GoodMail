import Foundation
import Testing
@testable import JMAPKit

struct JMAPClientTests {
    let transport = StubTransport()

    func makeClient() -> JMAPClient {
        JMAPClient(token: "secret", transport: transport, retryDelay: { _ in .zero })
    }

    @Test func fetchesSessionWithBearerToken() async throws {
        transport.enqueue(fixture: "session")
        let session = try await makeClient().session()

        #expect(session.username == "user@fastmail.com")
        #expect(try session.primaryAccountId(for: Capability.maskedEmail) == "u1234")
        #expect(session.supports(Capability.submission))
        #expect(!session.supports(Capability.contacts))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(
            session.downloadURL(accountId: "u1234", blobId: "b1", type: "image/png", name: "a b.png")?.absoluteString
                == "https://www.fastmailusercontent.com/jmap/download/u1234/b1/a%20b.png?type=image%2Fpng")
    }

    @Test func missingCapabilityThrows() async throws {
        transport.enqueue(fixture: "session")
        let session = try await makeClient().session()
        #expect(throws: JMAPError.missingCapability(Capability.contacts)) {
            try session.primaryAccountId(for: Capability.contacts)
        }
    }

    @Test func unauthorizedTokenThrows() async {
        transport.enqueue(.init(status: 401, body: Data()))
        await #expect(throws: JMAPError.unauthorized) {
            try await makeClient().session()
        }
    }

    @Test func retriesWhenRateLimited() async throws {
        transport.enqueue(.init(status: 429, body: Data(), headers: ["Retry-After": "0"]))
        transport.enqueue(.init(status: 503, body: Data()))
        transport.enqueue(fixture: "session")

        _ = try await makeClient().session()
        #expect(transport.requests.count == 3)
    }

    @Test func givesUpAfterMaxRetries() async {
        for _ in 0...3 { transport.enqueue(.init(status: 429, body: Data())) }
        await #expect(throws: JMAPError.rateLimited) {
            try await makeClient().session()
        }
    }

    @Test func getsMailboxes() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "mailbox_get")
        let client = makeClient()

        let accountId = try await client.accountId(for: Capability.mail)
        let response = try await client.call(MailboxGet(accountId: accountId))

        #expect(response.state == "m42")
        #expect(response.list.map(\.name) == ["Inbox", "Receipts"])
        #expect(response.list[0].role == .inbox)
        #expect(response.list[1].parentId == "mb1")

        let body = try #require(transport.requests.last?.jsonBody)
        #expect(body == [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            "methodCalls": [["Mailbox/get", ["accountId": "u1234", "ids": nil], "c0"]],
        ])
    }

    @Test func queryThenGetWithBackReference() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "email_query_get")
        let client = makeClient()

        var batch = Batch()
        let query = batch.add(EmailQuery(
            accountId: "u1234",
            filter: .and([.condition(.init(inMailbox: "mb1")), .not([.condition(.init(hasKeyword: "$seen"))])]),
            sort: [Comparator(property: "receivedAt", isAscending: false)],
            limit: 50,
            collapseThreads: true))
        let get = batch.add(EmailGet(
            accountId: "u1234", ids: .reference(query.reference("/ids")), properties: Email.Properties.full))
        let response = try await client.send(batch)

        #expect(try response.get(query).ids == ["e1"])
        let email = try #require(try response.get(get).list.first)
        #expect(email.subject == "Weekly deals")
        #expect(email.has(.seen))
        #expect(!email.has(.flagged))
        #expect(email.to?.first == EmailAddress(email: "shop.x7k2@fastmail.com"))
        #expect(email.listUnsubscribe == ["mailto:unsub@example.com", "https://example.com/u?id=1"])
        #expect(email.listUnsubscribePost == "List-Unsubscribe=One-Click")
        #expect(email.receivedAt == email.sentAt.map { $0.addingTimeInterval(1) })

        guard case .object(let body)? = transport.requests.last?.jsonBody,
              case .array(let calls)? = body["methodCalls"],
              case .array(let queryCall) = calls[0], case .array(let getCall) = calls[1],
              case .object(let queryArgs) = queryCall[1], case .object(let getArgs) = getCall[1]
        else { Issue.record("Unexpected request shape"); return }

        #expect(queryArgs["filter"] == [
            "operator": "AND",
            "conditions": [["inMailbox": "mb1"], ["operator": "NOT", "conditions": [["hasKeyword": "$seen"]]]],
        ])
        #expect(queryArgs["collapseThreads"] == true)
        #expect(getArgs["ids"] == nil)
        #expect(getArgs["#ids"] == ["resultOf": "c0", "name": "Email/query", "path": "/ids"])
    }

    @Test func methodErrorIsThrown() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s1", "methodResponses": [["error", {"type": "cannotCalculateChanges"}, "c0"]]}
            """.utf8)))

        await #expect(throws: JMAPError.method(MethodError(type: MethodError.cannotCalculateChanges, description: nil))) {
            try await makeClient().call(EmailChanges(accountId: "u1234", sinceState: "old"))
        }
    }

    @Test func refetchesSessionWhenStateChanges() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s2", "methodResponses": [["Mailbox/get",
              {"accountId": "u1234", "state": "m1", "list": [], "notFound": []}, "c0"]]}
            """.utf8)))
        transport.enqueue(fixture: "session")
        let client = makeClient()

        _ = try await client.call(MailboxGet(accountId: "u1234"))
        _ = try await client.session()
        #expect(transport.requests.count == 3)
    }

    @Test func replacedTokenIsUsedForRequestsAndPush() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "mailbox_get")
        let client = JMAPClient(token: "old", transport: transport, retryDelay: { _ in .zero })
        _ = try await client.call(MailboxGet(accountId: "u1234"))

        await client.setToken("new")
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "mailbox_get")
        _ = try await client.call(MailboxGet(accountId: "u1234"))
        let pushed = StubStream()
        pushed.finish()
        transport.enqueue(pushed)
        for try await _ in client.pushEvents() {}

        let tokens = transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        // The session is fetched again, as the new token may come with other scopes.
        #expect(tokens == ["Bearer old", "Bearer old", "Bearer new", "Bearer new", "Bearer new"])
        #expect(transport.requests.map { $0.url?.path() } == [
            "/jmap/session", "/jmap/api/", "/jmap/session", "/jmap/api/", "/jmap/event/",
        ])
    }

    @Test func createsMaskedEmail() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(fixture: "masked_email_set")

        let masked = try await makeClient().createMaskedEmail(
            .init(forDomain: "https://shop.example", description: "Shop", emailPrefix: "shop"))

        #expect(masked.id == "masked-1")
        #expect(masked.email == "shop.x7k2@fastmail.com")
        #expect(masked.state == .enabled)
        #expect(masked.forDomain == "https://shop.example")

        guard case .object(let body)? = transport.requests.last?.jsonBody,
              case .array(let calls)? = body["methodCalls"], case .array(let call) = calls[0]
        else { Issue.record("Unexpected request shape"); return }
        #expect(body["using"] == ["https://www.fastmail.com/dev/maskedemail", "urn:ietf:params:jmap:core"])
        #expect(call[1] == [
            "accountId": "u1234",
            "create": ["new": [
                "state": "enabled", "forDomain": "https://shop.example",
                "description": "Shop", "emailPrefix": "shop",
            ]],
        ])
    }

    @Test func maskedEmailUpdateFailureThrows() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data("""
            {"sessionState": "s1", "methodResponses": [["MaskedEmail/set",
              {"accountId": "u1234", "newState": "me3", "notUpdated": {"m1": {"type": "notFound"}}}, "c0"]]}
            """.utf8)))

        await #expect(throws: SetError(type: "notFound", description: nil, properties: nil)) {
            try await makeClient().setMaskedEmailState(id: "m1", .disabled)
        }
    }

    @Test(arguments: [("shop_2026", true), ("", false), ("Shop", false), ("a-b", false),
                      (String(repeating: "a", count: 65), false)])
    func validatesMaskedEmailPrefix(prefix: String, valid: Bool) {
        #expect(MaskedEmail.isValidPrefix(prefix) == valid)
    }
}
