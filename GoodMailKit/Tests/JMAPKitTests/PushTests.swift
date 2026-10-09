import Foundation
import Testing
@testable import JMAPKit

struct PushTests {
    let transport = StubTransport()

    func makeClient() -> JMAPClient {
        JMAPClient(token: "secret", transport: transport, retryDelay: { _ in .zero })
    }

    func session(eventSourceUrl: String) -> Session {
        Session(
            capabilities: [:], accounts: [:], primaryAccounts: [:], username: "user@example.com",
            apiUrl: URL(string: "https://jmap.example.com/api/")!, downloadUrl: "", uploadUrl: "",
            eventSourceUrl: eventSourceUrl, state: "s1")
    }

    /// A `state` event as the server sends it.
    func stateEvent(_ changed: String) -> String {
        "event: state\ndata: {\"@type\": \"StateChange\", \"changed\": \(changed)}\n\n"
    }

    /// Everything the stream yielded until it ended, and the error it ended with.
    func collect(_ events: AsyncThrowingStream<PushEvent, any Error>) async -> (events: [PushEvent], error: (any Error)?) {
        var collected: [PushEvent] = []
        do {
            for try await event in events { collected.append(event) }
            return (collected, nil)
        } catch {
            return (collected, error)
        }
    }

    // MARK: Event source URL

    @Test func expandsEventSourceTemplate() {
        let session = session(
            eventSourceUrl: "https://jmap.example.com/eventsource/?types={types}&closeafter={closeafter}&ping={ping}")

        #expect(session.eventSourceURL(types: ["Email", "Mailbox"], ping: 30)?.absoluteString
            == "https://jmap.example.com/eventsource/?types=Email,Mailbox&closeafter=no&ping=30")
        #expect(session.eventSourceURL(types: [], closeAfterState: true, ping: 0)?.absoluteString
            == "https://jmap.example.com/eventsource/?types=*&closeafter=state&ping=0")
    }

    @Test func addsVariablesMissingFromTemplateAsQueryItems() {
        #expect(session(eventSourceUrl: "https://jmap.example.com/event/").eventSourceURL(types: [], ping: 30)?
            .absoluteString == "https://jmap.example.com/event/?types=*&closeafter=no&ping=30")
        #expect(session(eventSourceUrl: "https://jmap.example.com/event/{types}?v=1&ping={ping}")
            .eventSourceURL(types: ["Email"], ping: 60)?.absoluteString
            == "https://jmap.example.com/event/Email?v=1&ping=60&closeafter=no")
    }

    @Test func decodesStateChange() throws {
        let change = try JSONDecoder().decode(StateChange.self, from: Data("""
            {"@type": "StateChange", "changed": {
              "a3123": {"Email": "d35ecb040aab", "EmailDelivery": "428d565f2440", "CalendarEvent": "87accfac587a"},
              "a43461d": {"Mailbox": "0af7a512ce70", "CalendarEvent": "7a4297cecd76"}}}
            """.utf8))

        #expect(change == StateChange(changed: [
            "a3123": ["Email": "d35ecb040aab", "EmailDelivery": "428d565f2440", "CalendarEvent": "87accfac587a"],
            "a43461d": ["Mailbox": "0af7a512ce70", "CalendarEvent": "7a4297cecd76"],
        ]))
    }

    // MARK: Push events

    @Test func yieldsStateChangesUntilTheServerEndsTheResponse() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream(sending: ": hello\n\n", "event: ping\ndata: {\"interval\": 30}\n\n",
                                stateEvent(#"{"u1234": {"Email": "e2", "Thread": "t2"}}"#),
                                "event: other\ndata: {}\n\n", stateEvent(#"{"u1234": {"Mailbox": "m3"}}"#))
        stream.finish()
        transport.enqueue(stream)

        let result = await collect(makeClient().pushEvents(types: ["Email", "Thread", "Mailbox"]))

        #expect(result.error == nil)
        #expect(result.events == [
            .connected,
            .stateChange(StateChange(changed: ["u1234": ["Email": "e2", "Thread": "t2"]])),
            .stateChange(StateChange(changed: ["u1234": ["Mailbox": "m3"]])),
        ])
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString
            == "https://api.fastmail.com/jmap/event/?types=Email,Thread,Mailbox&closeafter=no&ping=30")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.timeoutInterval > 2 * 30 + 15)
    }

    @Test func connectingAgainHandsBackTheIDOfTheLastEventSeen() async {
        transport.enqueue(fixture: "session")
        let first = StubStream(sending: "event: state\nid: s7\ndata: {\"@type\": \"StateChange\", \"changed\": {}}\n\n",
                               "event: ping\ndata: {\"interval\": 30}\n\n",
                               // Cut off by the connection dropping, so it was never seen.
                               "event: state\nid: s8\ndata: {\"@type\": \"StateChange\", \"changed\": {}}\n")
        first.finish(throwing: URLError(.networkConnectionLost))
        transport.enqueue(first)
        // Pings carry no id, so they don't make the client forget it.
        let second = StubStream(sending: "event: ping\ndata: {\"interval\": 30}\n\n")
        second.finish()
        transport.enqueue(second)
        let third = StubStream()
        third.finish()
        transport.enqueue(third)
        let client = makeClient()

        for _ in 0..<3 { _ = await collect(client.pushEvents()) }

        let connections = transport.requests.filter { $0.url?.path() == "/jmap/event/" }
        #expect(connections.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == [nil, "s7", "s7"])
    }

    @Test func readsEventsSplitAcrossChunks() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream(sending: "event: st", "ate\r", "\ndata: {\"@type\": \"StateChange\", \"chan",
                                "ged\": {\"u1234\": {\"Email\": \"e3\"}}}\r\n", "\r\n")
        stream.finish()
        transport.enqueue(stream)

        let result = await collect(makeClient().pushEvents())

        #expect(result.error == nil)
        #expect(result.events == [.connected, .stateChange(StateChange(changed: ["u1234": ["Email": "e3"]]))])
    }

    @Test func unauthorizedConnectionThrows() async {
        transport.enqueue(fixture: "session")
        transport.enqueue(StubStream(status: 401, headers: [:]))

        let result = await collect(makeClient().pushEvents())

        #expect(result.events.isEmpty)
        #expect(result.error as? JMAPError == .unauthorized)
    }

    @Test func rejectedConnectionThrowsItsStatusAndProblemType() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream(status: 429, headers: ["Content-Type": "application/problem+json"],
                                sending: #"{"type": "urn:ietf:params:jmap:error:limit", "status": 429}"#)
        stream.finish()
        transport.enqueue(stream)
        transport.enqueue(fixture: "session")
        let failing = StubStream(status: 503, headers: [:])
        failing.finish()
        transport.enqueue(failing)

        let limited = await collect(makeClient().pushEvents())
        let unavailable = await collect(makeClient().pushEvents())

        #expect(limited.events.isEmpty)
        #expect(limited.error as? JMAPError == .http(status: 429, problemType: JMAPError.limitProblemType))
        #expect(unavailable.error as? JMAPError == .http(status: 503, problemType: nil))
    }

    @Test func responseThatIsNoEventStreamThrows() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream(headers: ["Content-Type": "text/html"], sending: "<html>Sign in to the Wi-Fi</html>")
        stream.finish()
        transport.enqueue(stream)

        let result = await collect(makeClient().pushEvents())

        #expect(result.events.isEmpty)
        #expect(result.error as? JMAPError == .transport("Expected an event stream, got text/html"))
    }

    @Test func failingToConnectThrowsTransportError() async {
        transport.enqueue(fixture: "session")

        let result = await collect(makeClient().pushEvents())

        #expect(result.events.isEmpty)
        #expect(result.error as? JMAPError == .transport(URLError(.notConnectedToInternet).localizedDescription))
    }

    @Test func droppedConnectionThrowsTransportError() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream(sending: stateEvent(#"{"u1234": {"Email": "e2"}}"#))
        stream.finish(throwing: URLError(.networkConnectionLost))
        transport.enqueue(stream)

        let result = await collect(makeClient().pushEvents())

        #expect(result.events == [.connected, .stateChange(StateChange(changed: ["u1234": ["Email": "e2"]]))])
        #expect(result.error as? JMAPError == .transport(URLError(.networkConnectionLost).localizedDescription))
    }

    @Test func malformedStateChangeThrowsDecodingError() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream(sending: "event: state\ndata: {\"changed\": []}\n\n")
        stream.finish()
        transport.enqueue(stream)

        let result = await collect(makeClient().pushEvents())

        #expect(result.events == [.connected])
        guard case .decoding? = result.error as? JMAPError else {
            Issue.record("Expected a decoding error, got \(String(describing: result.error))")
            return
        }
    }

    @Test func transportThatCantStreamThrows() async {
        struct SendOnlyTransport: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                (Fixtures.data("session"),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let result = await collect(JMAPClient(token: "secret", transport: SendOnlyTransport()).pushEvents())

        #expect(result.error as? JMAPError == .transport("This transport can't stream"))
    }

    // MARK: Quiet connections

    @Test func quietConnectionFailsAndIsClosed() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream()
        transport.enqueue(stream)
        let start = ContinuousClock.now

        let result = await collect(makeClient().pushEvents(types: [], ping: 1, quietLimit: .milliseconds(300)))

        #expect(ContinuousClock.now - start >= .milliseconds(300))
        #expect(result.events == [.connected])
        #expect(result.error as? JMAPError == .transport("The push connection went quiet"))
        #expect(stream.wasCancelled)
    }

    @Test func anythingArrivingKeepsTheConnectionAlive() async {
        transport.enqueue(fixture: "session")
        let stream = StubStream()
        transport.enqueue(stream)
        let server = Task {
            for beat in 0..<15 {
                try await Task.sleep(for: .milliseconds(100))
                stream.send(beat.isMultiple(of: 2) ? "event: ping\ndata: {\"interval\": 1}\n\n" : ": still here\n")
            }
            stream.finish()
        }

        let result = await collect(makeClient().pushEvents(types: [], ping: 1, quietLimit: .seconds(1)))

        #expect(result.error == nil)
        #expect(result.events == [.connected])
        server.cancel()
    }

    @Test func pingOfZeroAsksForNoPings() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream()
        transport.enqueue(stream)

        var iterator = makeClient().pushEvents(types: ["Email"], ping: 0).makeAsyncIterator()
        #expect(try await iterator.next() == .connected)
        stream.send(stateEvent(#"{"u1234": {"Email": "e9"}}"#))
        #expect(try await iterator.next() == .stateChange(StateChange(changed: ["u1234": ["Email": "e9"]])))
        stream.finish()
        #expect(try await iterator.next() == nil)

        let request = try #require(transport.requests.last)
        #expect(request.url?.query() == "types=Email&closeafter=no&ping=0")
        #expect(request.timeoutInterval >= 60 * 60)
    }

    // MARK: Cancellation

    @Test func cancellingTheConsumerClosesTheConnection() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream()
        transport.enqueue(stream)
        let (connected, connectedContinuation) = AsyncStream<Void>.makeStream()
        let events = makeClient().pushEvents()
        let consumer = Task {
            for try await event in events where event == .connected { connectedContinuation.yield() }
        }

        for await _ in connected { break }
        #expect(!stream.wasCancelled)
        consumer.cancel()

        #expect(await eventually { stream.wasCancelled })
        _ = await consumer.result
    }

    @Test func droppingTheStreamClosesTheConnection() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream()
        transport.enqueue(stream)

        do {
            var iterator = makeClient().pushEvents().makeAsyncIterator()
            #expect(try await iterator.next() == .connected)
        }

        #expect(await eventually { stream.wasCancelled })
    }
}
