import Foundation
import Synchronization
@testable import JMAPKit

/// Replies to requests with queued responses and records what was sent.
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
        /// Fails the request with this code instead of answering, as URLSession does.
        var failure: URLError.Code?

        static func failing(_ code: URLError.Code) -> Reply {
            Reply(body: Data(), failure: code)
        }
    }

    private let state = Mutex<(replies: [Reply], streams: [StubStream], requests: [URLRequest])>(([], [], []))

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func enqueue(_ reply: Reply) {
        state.withLock { $0.replies.append(reply) }
    }

    func enqueue(fixture name: String, status: Int = 200) {
        enqueue(Reply(status: status, body: Fixtures.data(name)))
    }

    func enqueue(_ stream: StubStream) {
        state.withLock { $0.streams.append(stream) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        if let failure = reply.failure { throw URLError(failure) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let stream = state.withLock { state in
            state.requests.append(request)
            return state.streams.isEmpty ? nil : state.streams.removeFirst()
        }
        guard let stream else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stream.status, httpVersion: "HTTP/1.1", headerFields: stream.headers)!
        return (response, stream.body)
    }
}

/// A streamed response whose body the test writes while the client reads it.
final class StubStream: Sendable {
    let status: Int
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let cancelled = Mutex(false)

    /// Whether the reader went away before the body ended, which is how a request gets cancelled.
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    init(status: Int = 200, headers: [String: String] = ["Content-Type": "text/event-stream"], sending chunks: String...) {
        self.status = status
        self.headers = headers
        (body, continuation) = AsyncThrowingStream.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.cancelled.withLock { $0 = true } }
        }
        chunks.forEach(send)
    }

    func send(_ chunk: String) {
        send(Data(chunk.utf8))
    }

    func send(_ chunk: Data) {
        continuation.yield(chunk)
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }
}

enum Fixtures {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

extension URLRequest {
    /// The request body parsed as JSON, for asserting on what the client sent.
    var jsonBody: JSONValue? {
        httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}

/// Polls `condition` until it holds or `timeout` passes, for effects that land asynchronously.
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
