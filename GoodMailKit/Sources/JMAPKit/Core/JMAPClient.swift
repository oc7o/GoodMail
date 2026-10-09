import Foundation
import Synchronization

/// How a request answered with "try again later" (HTTP 429 or 503) is handled.
public enum RetryPolicy: Sendable {
    /// Waits and sends it again, a few times.
    case automatic
    /// Never sends it again, for requests that must not run twice, such as sending mail: a 503 may come after
    /// the server did the work. When the session can't be fetched first, the error is `sessionUnavailable`.
    case never
}

/// A JMAP client for a single account connection.
///
/// All thrown errors are `JMAPError`.
public actor JMAPClient {
    public static let fastmailSessionURL = URL(string: "https://api.fastmail.com/jmap/session")!

    private let sessionURL: URL
    /// In a mutex rather than isolated to the actor, so that the push connection can read it.
    private let token: Mutex<String>
    private let transport: any HTTPTransport
    private let maxRetries: Int
    private let retryDelay: @Sendable (_ attempt: Int) -> Duration

    private var cachedSession: Session?
    /// The id of the last event pushed to this client, handed back as `Last-Event-ID` when it connects again.
    private let lastEventID = Mutex("")

    public init(
        token: String,
        sessionURL: URL = JMAPClient.fastmailSessionURL,
        transport: any HTTPTransport = URLSessionTransport(),
        maxRetries: Int = 3,
        retryDelay: @escaping @Sendable (_ attempt: Int) -> Duration = { .seconds(1 << $0) }
    ) {
        self.token = Mutex(token)
        self.sessionURL = sessionURL
        self.transport = transport
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }

    // MARK: Session

    /// Returns the cached session, fetching it on first use or when `refresh` is set.
    public func session(refresh: Bool = false) async throws -> Session {
        if !refresh, let cachedSession { return cachedSession }
        let data = try await perform(URLRequest(url: sessionURL))
        let session: Session
        do {
            session = try JMAPCoding.makeDecoder().decode(Session.self, from: data)
        } catch {
            throw JMAPError.decoding("Session: \(error)")
        }
        cachedSession = session
        return session
    }

    public func accountId(for capability: String) async throws -> String {
        try await session().primaryAccountId(for: capability)
    }

    /// The session for a request about to be sent with `retry`.
    ///
    /// A timeout or 5xx while fetching the session would read as if the request itself may have run; for
    /// one that must not run twice, it is reported as `sessionUnavailable` instead.
    func session(for retry: RetryPolicy) async throws -> Session {
        do {
            return try await session()
        } catch let error as JMAPError where retry == .never && error.mayHaveReachedServer {
            throw JMAPError.sessionUnavailable(error)
        }
    }

    /// Uses `token` for every request and push connection from now on, and fetches the session again, as the
    /// new token may come with other capabilities.
    public func setToken(_ token: String) {
        self.token.withLock { $0 = token }
        cachedSession = nil
    }

    // MARK: API requests

    public func send(_ batch: Batch, retry: RetryPolicy = .automatic) async throws -> BatchResponse {
        let session = try await session(for: retry)
        var request = URLRequest(url: session.apiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JMAPCoding.makeEncoder().encode(batch)
        } catch {
            throw JMAPError.decoding("Encoding request: \(error)")
        }

        let data = try await perform(request, retry: retry)
        let response: BatchResponse
        do {
            response = try JMAPCoding.makeDecoder().decode(BatchResponse.self, from: data)
        } catch {
            throw JMAPError.decoding("Response: \(error)")
        }
        // The session changed (e.g. new account or capability); refetch it next time.
        if response.sessionState != session.state {
            cachedSession = nil
        }
        return response
    }

    /// Sends a single method call and returns its typed response.
    public func call<Call: MethodCall>(_ call: Call, retry: RetryPolicy = .automatic) async throws -> Call.Response {
        var batch = Batch()
        let handle = batch.add(call)
        return try await send(batch, retry: retry).get(handle)
    }

    // MARK: Push

    /// Changes as the server pushes them over its event source (RFC 8620 §7.3).
    ///
    /// Yields `.connected` once the server accepted the connection, then a `.stateChange` whenever one of `types`
    /// (all types when empty) changed. The server is asked to ping every `ping` seconds, and the connection counts
    /// as dead once nothing at all arrived for 2 × `ping` + 15 seconds; a `ping` of 0 turns both off.
    ///
    /// The stream finishes when the server ends the response and throws a `JMAPError` when the connection fails;
    /// it never reconnects by itself. Ending its iteration closes the connection. Connecting again tells the server
    /// which event this client got last, so that it can push what changed in between right away.
    public nonisolated func pushEvents(types: [String] = [], ping: Int = 30) -> AsyncThrowingStream<PushEvent, any Error> {
        pushEvents(types: types, ping: ping, quietLimit: ping > 0 ? .seconds(2 * ping + 15) : nil)
    }

    nonisolated func pushEvents(
        types: [String], ping: Int, quietLimit: Duration?
    ) -> AsyncThrowingStream<PushEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<PushEvent, any Error>.makeStream()
        let task = Task {
            do {
                try await receivePushEvents(types: types, ping: ping, quietLimit: quietLimit, into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error as? JMAPError ?? .transport(error.localizedDescription))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }

    private nonisolated func receivePushEvents(
        types: [String], ping: Int, quietLimit: Duration?,
        into continuation: AsyncThrowingStream<PushEvent, any Error>.Continuation
    ) async throws {
        guard let url = try await session().eventSourceURL(types: types, ping: ping) else {
            throw JMAPError.transport("Invalid event source URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.withLock { $0 })", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let lastEventID = self.lastEventID.withLock { $0 }
        if !lastEventID.isEmpty { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        // URLSession's idle timeout only backs up the quiet check, which notices sooner and says what happened.
        request.timeoutInterval = quietLimit.map { TimeInterval($0.components.seconds) + 60 } ?? 24 * 60 * 60

        let heartbeat = Heartbeat()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [request] in
                try await self.readEventStream(request, after: lastEventID, heartbeat: heartbeat, into: continuation)
            }
            if let quietLimit {
                group.addTask { try await heartbeat.failWhenQuiet(for: quietLimit) }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private nonisolated func readEventStream(
        _ request: URLRequest, after lastEventID: String, heartbeat: Heartbeat,
        into continuation: AsyncThrowingStream<PushEvent, any Error>.Continuation
    ) async throws {
        let (response, body) = try await transport.stream(request)
        heartbeat.beat()
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw JMAPError.unauthorized
        default:
            throw JMAPError.http(status: response.statusCode, problemType: await Self.problemType(in: body))
        }
        // An HTML page from a captive portal or proxy would parse as an empty stream and look like a connection.
        if let type = response.mimeType, type != "text/event-stream" {
            throw JMAPError.transport("Expected an event stream, got \(type)")
        }
        continuation.yield(.connected)

        var parser = EventStreamParser(lastEventID: lastEventID)
        for try await chunk in body {
            heartbeat.beat()
            for event in parser.parse(chunk) where event.type == "state" {
                let change: StateChange
                do {
                    change = try JSONDecoder().decode(StateChange.self, from: Data(event.data.utf8))
                } catch {
                    throw JMAPError.decoding("StateChange: \(error)")
                }
                continuation.yield(.stateChange(change))
            }
            let seen = parser.lastEventID
            self.lastEventID.withLock { $0 = seen }
        }
    }

    // MARK: HTTP

    func perform(_ request: URLRequest, retry: RetryPolicy = .automatic) async throws -> Data {
        let request = authorized(request)
        var attempt = 0
        // Once a 503 came, the request may have run, however the retries end (see `mayHaveReachedServer`).
        var unavailable: JMAPError?
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                throw Self.jmapError(error)
            }

            switch response.statusCode {
            case 200..<300:
                return data
            case 401:
                throw JMAPError.unauthorized
            case 429, 503:
                if response.statusCode == 503 {
                    unavailable = .http(status: 503, problemType: Self.problemType(in: data))
                }
                guard retry == .automatic, attempt < maxRetries else { throw unavailable ?? JMAPError.rateLimited }
                let delay = Self.retryAfter(response) ?? retryDelay(attempt)
                attempt += 1
                try? await Task.sleep(for: delay)
            default:
                throw JMAPError.http(status: response.statusCode, problemType: Self.problemType(in: data))
            }
        }
    }

    /// Sends `request` once and hands over its body as it arrives, for downloads too large to hold in memory.
    func performStreaming(
        _ request: URLRequest
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let response: HTTPURLResponse
        let body: AsyncThrowingStream<Data, any Error>
        do {
            (response, body) = try await transport.stream(authorized(request))
        } catch {
            throw Self.jmapError(error)
        }
        switch response.statusCode {
        case 200..<300:
            return (response, Self.mappingErrors(of: body))
        case 401:
            throw JMAPError.unauthorized
        default:
            throw JMAPError.http(status: response.statusCode, problemType: await Self.problemType(in: body))
        }
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token.withLock { $0 })", forHTTPHeaderField: "Authorization")
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        return request
    }

    /// Keeps the code of a `URLError`, which tells whether the request can have reached the server.
    static func jmapError(_ error: any Error) -> JMAPError {
        switch error {
        case let error as JMAPError: error
        case let error as URLError: .connection(error.code, error.localizedDescription)
        default: .transport(error.localizedDescription)
        }
    }

    /// `body` with its errors turned into `JMAPError`s; ending its iteration early still cancels the request.
    private static func mappingErrors(
        of body: AsyncThrowingStream<Data, any Error>
    ) -> AsyncThrowingStream<Data, any Error> {
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let forwarding = Task {
            do {
                for try await chunk in body { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: jmapError(error))
            }
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return chunks
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value), seconds >= 0
        else { return nil }
        return .seconds(min(seconds, 60))
    }

    private struct ProblemDetails: Decodable {
        let type: String?
    }

    private static func problemType(in data: Data) -> String? {
        (try? JSONDecoder().decode(ProblemDetails.self, from: data))?.type
    }

    /// The RFC 7807 problem type of a streamed error response, if it has one.
    private static func problemType(in body: AsyncThrowingStream<Data, any Error>) async -> String? {
        var data = Data()
        do {
            for try await chunk in body {
                data += chunk
                guard data.count <= 65_536 else { return nil }
            }
        } catch {
            return nil
        }
        return problemType(in: data)
    }
}

/// When a push connection last showed a sign of life.
private final class Heartbeat: Sendable {
    private let last = Mutex(ContinuousClock.now)

    func beat() {
        last.withLock { $0 = .now }
    }

    /// Throws once `limit` passed without a beat, and otherwise waits until cancelled.
    ///
    /// The continuous clock keeps counting while the device sleeps, after which the connection is likely gone.
    func failWhenQuiet(for limit: Duration) async throws {
        while true {
            let deadline = last.withLock { $0 } + limit
            guard deadline > .now else { throw JMAPError.transport("The push connection went quiet") }
            try await Task.sleep(until: deadline)
        }
    }
}
