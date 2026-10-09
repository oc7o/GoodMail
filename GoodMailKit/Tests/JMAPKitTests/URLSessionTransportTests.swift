import Foundation
import Synchronization
import Testing
@testable import JMAPKit

struct URLSessionTransportTests {
    let transport = URLSessionTransport(session: ScriptedURLProtocol.session)

    @Test func returnsTheHeadBeforeTheBodyAndEachChunkAsItArrives() async throws {
        let exchange = ScriptedURLProtocol.Exchange()
        exchange.run(.respond(200, headers: ["Content-Type": "text/event-stream"]))

        let (response, body) = try await transport.stream(URLRequest(url: exchange.url))
        #expect(response.statusCode == 200)
        #expect(response.mimeType == "text/event-stream")

        var chunks = body.makeAsyncIterator()
        exchange.run(.send("event: ping\n"))
        #expect(try await chunks.next() == Data("event: ping\n".utf8))
        exchange.run(.send("data: {}\n\n"))
        #expect(try await chunks.next() == Data("data: {}\n\n".utf8))
        exchange.run(.finish)
        #expect(try await chunks.next() == nil)
    }

    @Test func passesErrorResponsesOn() async throws {
        let exchange = ScriptedURLProtocol.Exchange()
        exchange.run(.respond(401, headers: [:]))
        exchange.run(.finish)

        let (response, body) = try await transport.stream(URLRequest(url: exchange.url))

        #expect(response.statusCode == 401)
        for try await _ in body {}
    }

    @Test func failsWhenTheConnectionFailsBeforeTheHead() async {
        let exchange = ScriptedURLProtocol.Exchange()
        exchange.run(.fail(.cannotConnectToHost))

        let error = await #expect(throws: URLError.self) {
            try await transport.stream(URLRequest(url: exchange.url))
        }
        #expect(error?.code == .cannotConnectToHost)
    }

    @Test func failsTheBodyWhenTheConnectionDrops() async throws {
        let exchange = ScriptedURLProtocol.Exchange()
        exchange.run(.respond(200, headers: ["Content-Type": "text/event-stream"]))
        let (_, body) = try await transport.stream(URLRequest(url: exchange.url))
        // Sent only now: URLSession drops data that arrives together with a failure before it handled the head.
        exchange.run(.send("data: a\n"))
        exchange.run(.fail(.networkConnectionLost))

        var received = Data()
        do {
            for try await chunk in body { received += chunk }
            Issue.record("The body should have failed")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
        #expect(received == Data("data: a\n".utf8))
    }

    @Test func endingTheBodyEarlyCancelsTheRequest() async throws {
        let exchange = ScriptedURLProtocol.Exchange()
        exchange.run(.respond(200, headers: ["Content-Type": "text/event-stream"]))
        exchange.run(.send("data: a\n"))

        do {
            let (_, body) = try await transport.stream(URLRequest(url: exchange.url))
            for try await _ in body { break }
        }

        #expect(await eventually { exchange.isStopped })
    }

    @Test func cancellingTheReaderCancelsTheRequest() async throws {
        let exchange = ScriptedURLProtocol.Exchange()
        exchange.run(.respond(200, headers: ["Content-Type": "text/event-stream"]))
        let (_, body) = try await transport.stream(URLRequest(url: exchange.url))

        let reader = Task { for try await _ in body {} }
        reader.cancel()
        _ = await reader.result

        #expect(await eventually { exchange.isStopped })
    }

    @Test func cancellingWhileWaitingForTheHeadCancelsTheRequest() async {
        let exchange = ScriptedURLProtocol.Exchange()
        let caller = Task { [transport] in
            try await transport.stream(URLRequest(url: exchange.url)).0.statusCode
        }

        #expect(await eventually { exchange.hasStarted })
        caller.cancel()

        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await eventually { exchange.isStopped })
    }

    @Test func cancelledCallerNeverStartsTheRequest() async {
        let exchange = ScriptedURLProtocol.Exchange()
        let caller = Task { [transport] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.stream(URLRequest(url: exchange.url)).0.statusCode
        }

        await #expect(throws: CancellationError.self) { try await caller.value }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!exchange.hasStarted)
    }
}

/// Serves responses a test scripts step by step, so `URLSessionTransport` runs real `URLSession` tasks offline.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    /// One request's response as the test drives it, found by the request's unique host.
    final class Exchange: Sendable {
        enum Step: Sendable {
            case respond(Int, headers: [String: String])
            case send(String)
            case finish
            case fail(URLError.Code)
        }

        private struct State {
            var pending: [Step] = []
            var perform: (@Sendable (Step) -> Void)?
            var hasStarted = false
            var isStopped = false
        }

        let url = URL(string: "https://\(UUID().uuidString.lowercased()).test/event/")!
        private let state = Mutex(State())

        var hasStarted: Bool { state.withLock { $0.hasStarted } }
        /// Whether the loading system stopped the request, which is what cancelling its task does.
        var isStopped: Bool { state.withLock { $0.isStopped } }

        init() {
            ScriptedURLProtocol.exchanges.withLock { $0[url.host()!] = self }
        }

        /// Performs `step` once the request started, in order with the steps before it.
        func run(_ step: Step) {
            state.withLock { state in
                if let perform = state.perform { perform(step) } else { state.pending.append(step) }
            }
        }

        fileprivate func start(performing perform: @escaping @Sendable (Step) -> Void) {
            state.withLock { state in
                state.hasStarted = true
                state.perform = perform
                state.pending.forEach(perform)
                state.pending = []
            }
        }

        fileprivate func stop() {
            state.withLock { state in
                state.isStopped = true
                state.perform = nil
            }
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    fileprivate static let exchanges = Mutex<[String: Exchange]>([:])

    private var exchange: Exchange?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// The loading system expects its client to be called on the thread that started loading.
    override func startLoading() {
        exchange = Self.exchanges.withLock { $0[request.url?.host() ?? ""] }
        guard let exchange else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        nonisolated(unsafe) let runLoop = CFRunLoopGetCurrent()
        exchange.start { step in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { self.perform(step) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    override func stopLoading() {
        exchange?.stop()
    }

    private func perform(_ step: Exchange.Step) {
        switch step {
        case .respond(let status, let headers):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .send(let text):
            client?.urlProtocol(self, didLoad: Data(text.utf8))
        case .finish:
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}
