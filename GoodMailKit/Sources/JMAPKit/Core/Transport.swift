import Foundation
import Synchronization

/// Abstraction over HTTP so the client can be tested without the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Sends a request whose response body keeps arriving, such as an event stream.
    ///
    /// Returns as soon as the response head arrives. The body follows chunk by chunk as it arrives and finishes
    /// when the response ends; ending its iteration early cancels the request.
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
}

extension HTTPTransport {
    public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        throw JMAPError.transport("This transport can't stream")
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeEphemeralSession()) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JMAPError.transport("Non-HTTP response")
        }
        return (data, http)
    }

    /// Uses a task delegate rather than `URLSession.bytes(for:)`, which hides where chunks end and so can't pass
    /// one on the moment it arrives.
    ///
    /// URLSession holds the head back until the first bytes of the body arrive, so this only returns then.
    public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let task = session.dataTask(with: request)
        let receiver = StreamReceiver(body: continuation)
        task.delegate = receiver
        continuation.onTermination = { _ in task.cancel() }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver.start(task, head: $0) }
        } onCancel: {
            receiver.cancel(task)
        }
        return (response, body)
    }

    /// No cookies, no URL cache on disk: mail content must only live in our encrypted store.
    public static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "GoodMail"]
        return URLSession(configuration: configuration)
    }
}

/// Hands a data task's response head to `URLSessionTransport.stream(_:)`, then its body to the body stream.
private final class StreamReceiver: NSObject, URLSessionDataDelegate, Sendable {
    typealias Head = CheckedContinuation<HTTPURLResponse, any Error>

    private enum Phase {
        case idle
        case awaitingHead(Head)
        /// The head was handed over, or nobody waits for it any more.
        case answered
    }

    private let body: AsyncThrowingStream<Data, any Error>.Continuation
    private let phase = Mutex(Phase.idle)

    init(body: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.body = body
    }

    /// Resumes the task, unless the caller was cancelled before it got here.
    func start(_ task: URLSessionDataTask, head: Head) {
        let isIdle = phase.withLock { phase in
            guard case .idle = phase else { return false }
            phase = .awaitingHead(head)
            return true
        }
        if isIdle {
            task.resume()
        } else {
            head.resume(throwing: CancellationError())
        }
    }

    /// For a caller cancelled while waiting for the head; once the body streams, ending its iteration cancels.
    func cancel(_ task: URLSessionDataTask) {
        takeHead()?.resume(throwing: CancellationError())
        task.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let head = takeHead()
        guard let http = response as? HTTPURLResponse else {
            head?.resume(throwing: JMAPError.transport("Non-HTTP response"))
            completionHandler(.cancel)
            return
        }
        head?.resume(returning: http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        takeHead()?.resume(throwing: error ?? URLError(.badServerResponse))
        body.finish(throwing: error)
    }

    private func takeHead() -> Head? {
        phase.withLock { phase in
            defer { phase = .answered }
            guard case .awaitingHead(let head) = phase else { return nil }
            return head
        }
    }
}
