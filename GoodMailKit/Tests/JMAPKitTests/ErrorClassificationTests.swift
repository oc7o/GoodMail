import Foundation
import Testing
@testable import JMAPKit

/// Whether a failed request may have run on the server decides whether sending mail can be tried again (C2).
struct ErrorClassificationTests {
    let transport = StubTransport()

    func makeClient() -> JMAPClient {
        JMAPClient(token: "secret", transport: transport, retryDelay: { _ in .zero })
    }

    /// Fails every request with a `URLError` of `code`, as URLSession does.
    private struct FailingTransport: HTTPTransport {
        let code: URLError.Code

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(code)
        }
    }

    private func failure(_ code: URLError.Code) async -> JMAPError? {
        do {
            _ = try await JMAPClient(token: "secret", transport: FailingTransport(code: code)).session()
            return nil
        } catch {
            return error as? JMAPError
        }
    }

    static let neverSent: [URLError.Code] = [
        .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .internationalRoamingOff,
        .dataNotAllowed, .callIsActive, .secureConnectionFailed, .serverCertificateHasBadDate,
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
        .badURL, .unsupportedURL,
    ]

    static let maybeSent: [URLError.Code] = [
        .timedOut, .networkConnectionLost, .cancelled, .badServerResponse, .cannotParseResponse,
        .zeroByteResource, .httpTooManyRedirects, .unknown,
    ]

    @Test(arguments: neverSent)
    func failuresBeforeTheRequestLeftAreCertainlyUnsent(code: URLError.Code) async {
        let error = await failure(code)
        #expect(error == .connection(code, URLError(code).localizedDescription))
        #expect(error?.mayHaveReachedServer == false)
        #expect(error?.isTemporary == true)
    }

    @Test(arguments: maybeSent)
    func failuresOnTheWayMayHaveReachedTheServer(code: URLError.Code) async {
        let error = await failure(code)
        #expect(error == .connection(code, URLError(code).localizedDescription))
        #expect(error?.mayHaveReachedServer == true)
        #expect(error?.isTemporary == true)
    }

    @Test(arguments: [408, 500, 502, 503, 504])
    func answersThatMayFollowTheWorkMayHaveReachedTheServer(status: Int) async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: status, body: Data()))
        var batch = Batch()
        batch.add(MailboxGet(accountId: "u1234"))

        let error = await #expect(throws: JMAPError.self) { try await makeClient().send(batch, retry: .never) }
        #expect(error == .http(status: status, problemType: nil))
        #expect(error?.mayHaveReachedServer == true)
    }

    @Test(arguments: [400, 403, 404, 409, 413, 422])
    func refusalsLeaveTheServerUntouched(status: Int) async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: status, body: Data(#"{"type": "urn:ietf:params:jmap:error:limit"}"#.utf8)))
        var batch = Batch()
        batch.add(MailboxGet(accountId: "u1234"))

        let error = await #expect(throws: JMAPError.self) { try await makeClient().send(batch, retry: .never) }
        #expect(error == .http(status: status, problemType: JMAPError.limitProblemType))
        #expect(error?.mayHaveReachedServer == false)
    }

    @Test func otherErrorsAreClassifiedByWhetherTheServerAnswered() {
        #expect(!JMAPError.rateLimited.mayHaveReachedServer)
        #expect(!JMAPError.unauthorized.mayHaveReachedServer)
        #expect(!JMAPError.missingCapability(Capability.submission).mayHaveReachedServer)
        #expect(JMAPError.transport("Socket closed").mayHaveReachedServer)
        #expect(JMAPError.decoding("Response: truncated").mayHaveReachedServer)
        #expect(JMAPError.unexpectedResponse(callId: "c1").mayHaveReachedServer)
        // A method error leaves the server as it was, unless it says that it got halfway (RFC 8620 §3.6.2).
        #expect(!JMAPError.method(MethodError(type: MethodError.serverUnavailable)).mayHaveReachedServer)
        #expect(!JMAPError.method(MethodError(type: "serverFail")).mayHaveReachedServer)
        #expect(JMAPError.method(MethodError(type: MethodError.serverPartialFail)).mayHaveReachedServer)
    }

    /// The session request failing ambiguously says nothing about the request after it, which was never sent.
    @Test func requestThatMustNotRunTwiceWasUnsentWhenItsSessionFailed() async {
        var batch = Batch()
        batch.add(MailboxGet(accountId: "u1234"))
        let timeout = JMAPError.connection(.timedOut, URLError(.timedOut).localizedDescription)
        let offline = JMAPError.connection(.notConnectedToInternet, URLError(.notConnectedToInternet).localizedDescription)

        transport.enqueue(.failing(.timedOut))
        await #expect(throws: JMAPError.sessionUnavailable(timeout)) { try await makeClient().send(batch, retry: .never) }
        transport.enqueue(.failing(.timedOut))
        await #expect(throws: timeout) { try await makeClient().send(batch) }
        // Already certain: kept as it is, so that being offline still reads as such.
        transport.enqueue(.failing(.notConnectedToInternet))
        await #expect(throws: offline) { try await makeClient().send(batch, retry: .never) }

        #expect(transport.requests.count == 3)
        #expect(!JMAPError.sessionUnavailable(timeout).mayHaveReachedServer)
        #expect(JMAPError.sessionUnavailable(timeout).isTemporary)
        #expect(!JMAPError.sessionUnavailable(.decoding("Session: truncated")).isTemporary)
    }

    @Test func connectionErrorsReadLikeTheSystemsMessage() {
        let message = URLError(.timedOut).localizedDescription
        #expect(JMAPError.connection(.timedOut, message).localizedDescription == message)
    }

    // MARK: Retrying

    @Test(arguments: [(429, JMAPError.rateLimited), (503, JMAPError.http(status: 503, problemType: nil))])
    func requestsThatMustNotRunTwiceAreSentOnce(status: Int, expected: JMAPError) async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: status, body: Data(), headers: ["Retry-After": "0"]))
        transport.enqueue(fixture: "mailbox_get")
        var batch = Batch()
        batch.add(MailboxGet(accountId: "u1234"))

        await #expect(throws: expected) { try await makeClient().send(batch, retry: .never) }
        #expect(transport.requests.count == 2)
    }

    @Test func otherRequestsAreRetriedAsBefore() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: 429, body: Data(), headers: ["Retry-After": "0"]))
        transport.enqueue(.init(status: 503, body: Data()))
        transport.enqueue(fixture: "mailbox_get")
        var batch = Batch()
        let get = batch.add(MailboxGet(accountId: "u1234"))

        let response = try await makeClient().send(batch)

        #expect(try response.get(get).list.count == 2)
        #expect(transport.requests.count == 4)
    }

    @Test func automaticRetriesStillGiveUp() async {
        transport.enqueue(fixture: "session")
        for _ in 0...3 { transport.enqueue(.init(status: 429, body: Data(), headers: ["Retry-After": "0"])) }

        await #expect(throws: JMAPError.rateLimited) { try await makeClient().call(MailboxGet(accountId: "u1234")) }
        #expect(transport.requests.count == 5)
    }

    /// A 503 may come after the server did the work, so retries that run out after one don't count as refused.
    @Test(arguments: [[503, 503, 503, 503], [503, 429, 429, 429], [429, 429, 429, 503]])
    func retriesRunningOutAfterABusyAnswerMayHaveReachedTheServer(statuses: [Int]) async {
        transport.enqueue(fixture: "session")
        for status in statuses { transport.enqueue(.init(status: status, body: Data(), headers: ["Retry-After": "0"])) }

        let error = await #expect(throws: JMAPError.self) { try await makeClient().call(MailboxGet(accountId: "u1234")) }

        #expect(error == .http(status: 503, problemType: nil))
        #expect(error?.mayHaveReachedServer == true)
        #expect(error?.isTemporary == true)
        #expect(transport.requests.count == 5)
    }
}
