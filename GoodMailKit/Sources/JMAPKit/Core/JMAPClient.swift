import Foundation
import Synchronization

/// A JMAP client for a single account connection.
///
/// All thrown errors are `JMAPError`.
public actor JMAPClient {
    public static let fastmailSessionURL = URL(string: "https://api.fastmail.com/jmap/session")!

    private let sessionURL: URL
    private let token: String
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
        self.token = token
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

    // MARK: API requests

    public func send(_ batch: Batch) async throws -> BatchResponse {
        let session = try await session()
        var request = URLRequest(url: session.apiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JMAPCoding.makeEncoder().encode(batch)
        } catch {
            throw JMAPError.decoding("Encoding request: \(error)")
        }

        let data = try await perform(request)
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
    public func call<Call: MethodCall>(_ call: Call) async throws -> Call.Response {
        var batch = Batch()
        let handle = batch.add(call)
        return try await send(batch).get(handle)
    }

    // MARK: Blobs

    /// Downloads a blob such as an attachment or inline image from the mail account.
    public func download(blobId: String, type: String = "application/octet-stream", name: String = "blob") async throws -> Data {
        let session = try await session()
        let accountId = try session.primaryAccountId(for: Capability.mail)
        guard let url = session.downloadURL(accountId: accountId, blobId: blobId, type: type, name: name) else {
            throw JMAPError.transport("Invalid download URL")
        }
        var request = URLRequest(url: url)
        request.setValue(type, forHTTPHeaderField: "Accept")
        return try await perform(request)
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        var attempt = 0
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as JMAPError {
                throw error
            } catch {
                throw JMAPError.transport(error.localizedDescription)
            }

            switch response.statusCode {
            case 200..<300:
                return data
            case 401:
                throw JMAPError.unauthorized
            case 429, 503:
                guard attempt < maxRetries else { throw JMAPError.rateLimited }
                let delay = Self.retryAfter(response) ?? retryDelay(attempt)
                attempt += 1
                try? await Task.sleep(for: delay)
            default:
                let problem = try? JSONDecoder().decode(ProblemDetails.self, from: data)
                throw JMAPError.http(status: response.statusCode, problemType: problem?.type)
            }
        }
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
        return (try? JSONDecoder().decode(ProblemDetails.self, from: data))?.type
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
