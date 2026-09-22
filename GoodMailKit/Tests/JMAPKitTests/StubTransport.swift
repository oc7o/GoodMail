import Foundation
import Synchronization
@testable import JMAPKit

/// Replies to requests with queued responses and records what was sent.
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    private let state = Mutex<(replies: [Reply], requests: [URLRequest])>(([], []))

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func enqueue(_ reply: Reply) {
        state.withLock { $0.replies.append(reply) }
    }

    func enqueue(fixture name: String, status: Int = 200) {
        enqueue(Reply(status: status, body: Fixtures.data(name)))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
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
