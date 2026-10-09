import DemoAccount
import Foundation
import JMAPKit
import MailCompose
import MailStore
import Synchronization
@testable import GoodMailCore

/// The demo server's manual clock as the outbox's: deadlines pass only when a test advances it.
struct OutboxTestClock: OutboxClock {
    let clock: DemoClock

    var now: Date { clock.now }

    func sleep(until date: Date) async throws {
        await clock.wait(until: date)
        try Task.checkCancellation()
    }
}

/// A network path a test switches; it starts online.
final class OutboxTestNetwork: NetworkPathSource {
    private struct State {
        var path: NetworkPath
        var listeners: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ path: NetworkPath = NetworkPath(isSatisfied: true)) {
        state = Mutex(State(path: path))
    }

    func paths() -> AsyncStream<NetworkPath> {
        let (paths, continuation) = AsyncStream.makeStream(of: NetworkPath.self)
        let id = UUID()
        state.withLock { state in
            continuation.yield(state.path)
            state.listeners[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.listeners[id] = nil } }
        return paths
    }

    func set(_ path: NetworkPath) {
        let listeners = state.withLock { state in
            state.path = path
            return Array(state.listeners.values)
        }
        for listener in listeners { listener.yield(path) }
    }
}

/// The demo server behind a transport that counts the calls it sees, and can hold back requests (uploads, or
/// calls to one method) until released, or prepare the server just before a given call reaches it.
final class OutboxTestTransport: HTTPTransport {
    private struct State {
        var held: Set<String> = []
        var waiting: [(name: String, resume: CheckedContinuation<Void, Never>)] = []
        var calls: [String: Int] = [:]
        var bodies: [Data] = []
        var beforeNext: [(name: String, action: @Sendable () -> Void)] = []
        var eventSourceURLs: [URL] = []
    }

    /// What `hold(_:)` takes for an upload, as opposed to a method.
    static let upload = "upload"

    let server: DemoTransport
    private let state = Mutex(State())

    init(server: DemoTransport) {
        self.server = server
    }

    /// Requests calling `name` (or uploads, for `upload`) wait from now on until `release(_:)`.
    func hold(_ name: String) {
        state.withLock { _ = $0.held.insert(name) }
    }

    /// Lets the held requests for `name` through, and holds no more.
    func release(_ name: String) {
        let waiting = state.withLock { state in
            state.held.remove(name)
            let released = state.waiting.filter { $0.name == name }
            state.waiting.removeAll { $0.name == name }
            return released
        }
        for request in waiting { request.resume.resume() }
    }

    var heldRequests: Int {
        state.withLock { $0.waiting.count }
    }

    /// Runs `action` right before the next request calling `name` reaches the server, e.g. to have the server
    /// lose that request's answer.
    func beforeNext(_ name: String, _ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.beforeNext.append((name, action)) }
    }

    func calls(to name: String) -> Int {
        state.withLock { $0.calls[name, default: 0] }
    }

    /// Every call to `name` so far, with its arguments.
    func arguments(of name: String) -> [JSONValue] {
        let bodies = state.withLock { $0.bodies }
        return bodies.flatMap { body -> [JSONValue] in
            guard case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: body),
                  case .array(let calls)? = request["methodCalls"]
            else { return [] }
            return calls.compactMap { call in
                guard case .array(let triple) = call, triple.count == 3, triple[0] == .string(name) else { return nil }
                return triple[1]
            }
        }
    }

    var eventSourceURLs: [URL] {
        state.withLock { $0.eventSourceURLs }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let names = Self.names(of: request)
        let (held, actions) = state.withLock { state -> (String?, [@Sendable () -> Void]) in
            for name in names { state.calls[name, default: 0] += 1 }
            if names != [Self.upload], let body = request.httpBody { state.bodies.append(body) }
            var actions: [@Sendable () -> Void] = []
            for name in names {
                if let index = state.beforeNext.firstIndex(where: { $0.name == name }) {
                    actions.append(state.beforeNext.remove(at: index).action)
                }
            }
            return (names.first(where: state.held.contains), actions)
        }
        if let held {
            await withCheckedContinuation { continuation in
                let isHeld = state.withLock { state in
                    guard state.held.contains(held) else { return false }
                    state.waiting.append((held, continuation))
                    return true
                }
                if !isHeld { continuation.resume() }
            }
        }
        for action in actions { action() }
        return try await server.send(request)
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        if let url = request.url, url.path().hasSuffix("/event/") {
            state.withLock { $0.eventSourceURLs.append(url) }
        }
        return try await server.stream(request)
    }

    private static func names(of request: URLRequest) -> [String] {
        if request.url?.path().contains("/upload/") == true { return [upload] }
        guard let body = request.httpBody,
              case .object(let envelope)? = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .array(let calls)? = envelope["methodCalls"]
        else { return [] }
        return calls.compactMap { call in
            guard case .array(let triple) = call, case .string(let name)? = triple.first else { return nil }
            return name
        }
    }
}

/// A model against the demo account on a manual clock, online, with the store on the same clock: everything
/// time-dependent happens when a test advances the clock, never in real time.
@MainActor
final class OutboxTestAccount {
    /// 2026-10-09T14:00:00Z
    static let start = Date(timeIntervalSince1970: 1_791_554_400)

    let clock = DemoClock(manualStart: OutboxTestAccount.start)
    let server: DemoTransport
    let transport: OutboxTestTransport
    let network = OutboxTestNetwork()
    let store: MailStore
    private(set) var model: MailModel
    private let maxRetries: Int

    /// - Parameter maxRetries: How often the model's client retries a busy answer by itself.
    init(supportsSubmission: Bool = true, maxRetries: Int = 0) throws {
        server = DemoTransport(clock: clock, supportsSubmission: supportsSubmission)
        transport = OutboxTestTransport(server: server)
        let clock = clock
        store = try MailStore(now: { clock.now })
        self.maxRetries = maxRetries
        model = Self.makeModel(
            transport: transport, store: store, clock: clock, network: network, maxRetries: maxRetries)
    }

    isolated deinit {
        model.stop()
    }

    private static func makeModel(
        transport: OutboxTestTransport, store: MailStore, clock: DemoClock, network: OutboxTestNetwork,
        maxRetries: Int, syncsInBackground: Bool = false
    ) -> MailModel {
        let model = MailModel(
            client: JMAPClient(token: "demo", transport: transport, maxRetries: maxRetries, retryDelay: { _ in .zero }),
            store: store, syncsInBackground: syncsInBackground, clock: OutboxTestClock(clock: clock), network: network,
            onUnauthorized: {})
        model.pushRetryDelay = { _ in .milliseconds(10) }
        return model
    }

    var outbox: Outbox { model.outbox }

    /// A client of the demo server that the model doesn't share, for looking at what the server has.
    var client: JMAPClient { JMAPClient(token: "demo", transport: server, maxRetries: 0) }

    /// Starts the model and lists the inbox, as the app does, and lets the outbox finish its first pass.
    func start() async {
        await model.start()
        await model.loadThreads()
        await settle()
    }

    /// A new model on the same store and server, as after a relaunch.
    @discardableResult
    func relaunch(syncsInBackground: Bool = false) -> MailModel {
        model.stop()
        model = Self.makeModel(
            transport: transport, store: store, clock: clock, network: network, maxRetries: maxRetries,
            syncsInBackground: syncsInBackground)
        return model
    }

    /// Waits until nothing runs in the outbox any more, then makes one full pass and waits again.
    func settle() async {
        await outbox.waitUntilIdle()
        _ = await outbox.flushNow()
        await outbox.waitUntilIdle()
    }

    /// Moves time on the server and the device, then lets the outbox act on it.
    func advance(_ seconds: TimeInterval) async {
        server.advanceClock(by: seconds)
        await settle()
    }

    /// Switches the network path and waits until the model has noticed.
    func setOnline(_ isOnline: Bool) async {
        network.set(NetworkPath(isSatisfied: isOnline))
        for _ in 0..<1000 where model.isOnline != isOnline { await Task.yield() }
    }

    func row(_ id: UUID) async throws -> StoredDraft? {
        try await store.draft(id: id.uuidString)
    }

    func record(_ id: UUID) async throws -> OutboxRecord? {
        try await row(id)?.record
    }

    /// The server's copy of an email, with its body.
    func serverEmail(_ id: String) async throws -> Email? {
        try await client.emails(ids: [id]).first
    }

    /// The emails on the server with the Message-ID, as `[id: mailboxIds]`.
    func copies(of messageID: String) async throws -> [String: [String: Bool]] {
        let lookup = try await client.emails(withMessageID: messageID)
        return Dictionary(uniqueKeysWithValues: lookup.matches.map { ($0.id, $0.mailboxIds) })
    }

    /// A new message to Maya, edited and saved here.
    func composeToMaya(subject: String = "Lunch", text: String = "See you at noon") async throws -> Composer {
        let composer = try await model.compose(.new())
        composer.to = [EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example")]
        composer.subject = subject
        composer.body = AttributedString(text)
        return composer
    }
}
