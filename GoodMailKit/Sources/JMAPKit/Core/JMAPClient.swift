import Foundation

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

    // MARK: HTTP

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
}
