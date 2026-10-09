import DemoAccount
import Foundation
import JMAPKit
import MailStore
import Synchronization
import Testing
@testable import GoodMailCore

/// Live updates against the demo account, which pushes its changes like Fastmail's event source does.
@MainActor
struct MailModelPushTests {
    let transport = RecordingTransport()
    let store: MailStore
    var server: DemoTransport { transport.server }

    init() throws {
        store = try MailStore()
    }

    private func makeModel(syncsInBackground: Bool = true, onUnauthorized: @escaping () -> Void = {}) -> MailModel {
        let model = MailModel(
            client: JMAPClient(token: "demo", transport: transport, maxRetries: 0), store: store,
            syncsInBackground: syncsInBackground, onUnauthorized: onUnauthorized)
        model.pushRetryDelay = { _ in .milliseconds(10) }
        return model
    }

    /// Starts the model and waits until changes are pushed and the refresh catching up on connecting is done,
    /// so that whatever happens next can only arrive by push.
    private func connect(_ model: MailModel) async throws {
        await model.start()
        await model.loadThreads()
        try #require(await eventually { model.isPushConnected })
        await model.refresh()
    }

    private func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func stateEvent(_ changed: [String: [String: String]]) throws -> Data {
        let change = try JSONSerialization.data(withJSONObject: ["@type": "StateChange", "changed": changed])
        return Data("event: state\ndata: ".utf8) + change + Data("\n\n".utf8)
    }

    @Test func newMailShowsUpAsSoonAsItIsPushed() async throws {
        let model = makeModel()
        defer { model.stop() }
        try await connect(model)
        #expect(server.openEventStreams == 1)

        server.deliver(id: "new1", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")

        try #require(await eventually { model.threads.first?.id == "tNew" })
        #expect(model.mailbox(.inbox)?.unreadThreads == 3)
    }

    @Test func maskedEmailChangedElsewhereIsReloadedWithoutRefreshingMail() async throws {
        let model = makeModel()
        defer { model.stop() }
        try await connect(model)
        let mailSyncs = transport.calls(to: "Email/changes")

        server.setMaskedEmailState(id: "masked-1", to: "disabled")

        try #require(await eventually { model.maskedEmails.first { $0.id == "masked-1" }?.state == .disabled })
        // Joins a refresh still under way, if the change started one, which would then make two.
        await model.refresh()
        #expect(transport.calls(to: "Email/changes") == mailSyncs + 1)
    }

    @Test func changesToOtherAccountsAreIgnored() async throws {
        let (body, push) = AsyncThrowingStream<Data, any Error>.makeStream()
        transport.serveNextEventSource(body: body)
        let model = makeModel()
        defer { model.stop() }
        try await connect(model)
        let mailSyncs = transport.calls(to: "Email/changes")
        let maskedEmailLoads = transport.calls(to: "MaskedEmail/get")

        push.yield(try stateEvent(["elsewhere": ["Email": "9", "Mailbox": "9", "MaskedEmail": "9"]]))
        push.yield(try stateEvent(["demo": ["MaskedEmail": "2"]]))

        // Changes are taken in order, so the first one is through once the second shows.
        try #require(await eventually { transport.calls(to: "MaskedEmail/get") > maskedEmailLoads })
        // Each joins a run still under way, if any, so a run the first change started would add one more.
        await model.refresh()
        await model.loadMaskedEmails()
        #expect(transport.calls(to: "Email/changes") == mailSyncs + 1)
        #expect(transport.calls(to: "MaskedEmail/get") == maskedEmailLoads + 2)
    }

    @Test func reconnectsAfterTheConnectionDropsAndCatchesUp() async throws {
        let model = makeModel()
        defer { model.stop() }
        try await connect(model)
        let connections = server.eventStreamConnections

        server.isOffline = true
        try #require(await eventually { !model.isPushConnected })
        #expect(model.connectionProblem == nil)
        #expect(model.errorMessage == nil)

        // Never pushed: no connection is open, and with no event seen so far the next can't say what it missed.
        server.deliver(id: "new1", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        server.isOffline = false

        try #require(await eventually { model.isPushConnected })
        #expect(server.eventStreamConnections == connections + 1)
        try #require(await eventually { model.threads.first?.id == "tNew" })
    }

    @Test func mailMissedWhileDisconnectedIsPushedAsSoonAsItReconnects() async throws {
        let model = makeModel()
        defer { model.stop() }
        try await connect(model)
        // As with URLSession, a connection only shows with the first event the server sends. Unless the server learns
        // what this client saw last and pushes what it missed, that is its first ping, half a minute later.
        transport.withholdsHeads = true
        server.deliver(id: "new1", threadId: "tNew1", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        try #require(await eventually { model.threads.contains { $0.id == "tNew1" } })
        server.isOffline = true
        try #require(await eventually { !model.isPushConnected })
        server.deliver(id: "new2", threadId: "tNew2", from: "Jonas", subject: "Or Friday?", text: "Works too.")

        server.isOffline = false

        try #require(await eventually { model.threads.contains { $0.id == "tNew2" } })
        #expect(model.isPushConnected)
    }

    @Test func comingBackToTheAppReconnectsWithoutWaitingOutTheBackoff() async throws {
        let model = makeModel()
        model.pushRetryDelay = { _ in .seconds(3600) }
        defer { model.stop() }
        try await connect(model)
        server.isOffline = true
        try #require(await eventually { !model.isPushConnected })
        server.isOffline = false

        model.resumePush()

        try #require(await eventually { model.isPushConnected })
        #expect(server.eventStreamConnections == 2)
    }

    @Test func connectionsEndingRightAfterTheyAreAcceptedBackOffUntilOneLasts() async throws {
        let (lasting, end) = AsyncThrowingStream<Data, any Error>.makeStream()
        transport.serveNextEventSource()
        transport.serveNextEventSource()
        transport.serveNextEventSource(body: lasting)
        var waits: [Int] = []
        let model = makeModel()
        model.pushRetryDelay = { failures in
            waits.append(failures)
            return .milliseconds(10)
        }
        model.stablePushConnection = .milliseconds(500)
        defer { model.stop() }

        await model.start()
        try #require(await eventually { transport.eventSourceRequests == 3 && model.isPushConnected })
        try await Task.sleep(for: .seconds(1))
        end.finish()

        try #require(await eventually { server.openEventStreams == 1 && model.isPushConnected })
        #expect(waits == [0, 1, 0])
    }

    @Test func stoppingClosesTheConnectionForGood() async throws {
        let model = makeModel()
        defer { model.stop() }
        try await connect(model)

        model.stop()

        #expect(!model.isPushConnected)
        try #require(await eventually { server.openEventStreams == 0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.eventStreamConnections == 1)
    }

    /// Stops while `start()` waits for its first refresh, or for loading masked emails after it.
    @Test(arguments: ["Mailbox/get", "MaskedEmail/get"])
    func stoppingWhileStartingCancelsWhatItWaitsForAndStartsNothingMore(_ method: String) async throws {
        let model = makeModel()
        defer { model.stop() }
        transport.hold(method)
        let starting = Task { await model.start() }
        try #require(await eventually { transport.heldAnswers == 1 })
        let calls = transport.callCount
        // Lets the answer through after all if stopping doesn't cancel it, so that the test fails instead of hanging.
        let fallback = Task { try await Task.sleep(for: .seconds(3)); transport.release() }
        defer { fallback.cancel() }

        model.stop()
        await starting.value

        #expect(transport.cancelledAnswers == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.callCount == calls)
        #expect(transport.eventSourceRequests == 0)
        #expect(!model.isPushConnected)
        #expect(model.connectionProblem == nil)
    }

    @Test func rejectedTokenEndsPushingWithoutAnError() async throws {
        transport.serveNextEventSource(status: 401)
        var rejections = 0
        let model = makeModel { rejections += 1 }
        defer { model.stop() }

        await model.start()

        try #require(await eventually { rejections == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.eventSourceRequests == 1)
        #expect(rejections == 1)
        #expect(!model.isPushConnected)
        #expect(model.errorMessage == nil)
    }

    @Test func refreshesWhileOneRunsShareOneMorePassThatMissesNothing() async throws {
        let model = makeModel(syncsInBackground: false)
        await model.start()
        await model.loadThreads()
        transport.hold("Email/changes")

        let first = Task { await model.refresh() }
        try #require(await eventually { transport.heldAnswers == 1 })
        let mailSyncs = transport.calls(to: "Email/changes")
        // The running refresh has asked the server already, so only another pass brings this in.
        server.deliver(id: "new1", threadId: "tNew", from: "Jonas", subject: "Lunch?", text: "Tomorrow?")
        // Queued on the main actor ahead of the first refresh's next step, so they find it running.
        let more = [Task { await model.refresh() }, Task { await model.refresh() }, Task { await model.refresh() }]
        transport.release()

        await more[0].value
        #expect(model.threads.first?.id == "tNew")
        await first.value
        for refresh in more { await refresh.value }
        #expect(transport.calls(to: "Email/changes") == mailSyncs + 1)
    }
}

/// The demo server, counting the methods it is asked to run. It can also hold back answers to one method, and
/// answer the event source with responses of the test's own.
///
/// Like `URLSessionTransport`, it fails the requests of a cancelled task, including held ones.
final class RecordingTransport: HTTPTransport {
    private struct State {
        var calls: [String: Int] = [:]
        var heldMethod: String?
        var holds = 0
        var heldAnswers: [Int: CheckedContinuation<Void, any Error>] = [:]
        var cancelledAnswers = 0
        var nextEventSources: [(status: Int, body: AsyncThrowingStream<Data, any Error>)] = []
        var eventSourceRequests = 0
        var withholdsHeads = false
    }

    let server = DemoTransport()
    private let state = Mutex(State())

    func calls(to method: String) -> Int {
        state.withLock { $0.calls[method, default: 0] }
    }

    /// Method calls of any kind.
    var callCount: Int {
        state.withLock { $0.calls.values.reduce(0, +) }
    }

    /// Answers to requests calling `method` wait until `release()`.
    func hold(_ method: String) {
        state.withLock { $0.heldMethod = method }
    }

    var heldAnswers: Int {
        state.withLock { $0.heldAnswers.count }
    }

    /// Held answers that never came because their task was cancelled.
    var cancelledAnswers: Int {
        state.withLock { $0.cancelledAnswers }
    }

    func release() {
        let held = state.withLock { state in
            state.heldMethod = nil
            defer { state.heldAnswers = [:] }
            return state.heldAnswers.values
        }
        held.forEach { $0.resume() }
    }

    /// Answers an event-source request with `status` and `body` instead of the demo server's stream; several calls
    /// answer that many requests in turn.
    func serveNextEventSource(status: Int = 200, body: AsyncThrowingStream<Data, any Error> = .init { $0.finish() }) {
        state.withLock { $0.nextEventSources.append((status, body)) }
    }

    var eventSourceRequests: Int {
        state.withLock { $0.eventSourceRequests }
    }

    /// Whether event-source responses only come once the first bytes of their body do, as from URLSession.
    var withholdsHeads: Bool {
        get { state.withLock { $0.withholdsHeads } }
        set { state.withLock { $0.withholdsHeads = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if Task.isCancelled { throw URLError(.cancelled) }
        let body = request.httpBody ?? Data()
        let calls = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["methodCalls"] as? [[Any]] ?? []
        let methods = calls.compactMap { $0.first as? String }
        state.withLock { state in methods.forEach { state.calls[$0, default: 0] += 1 } }
        let answer = try await server.send(request)
        try await holdIfAsked(methods)
        return answer
    }

    private func holdIfAsked(_ methods: [String]) async throws {
        let hold = state.withLock { state -> Int? in
            guard let held = state.heldMethod, methods.contains(held) else { return nil }
            state.holds += 1
            return state.holds
        }
        guard let hold else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { answer in
                state.withLock { $0.heldAnswers[hold] = answer }
                // Cancelled before the answer was there to cancel.
                if Task.isCancelled { cancel(hold) }
            }
        } onCancel: {
            cancel(hold)
        }
    }

    private func cancel(_ hold: Int) {
        let answer = state.withLock { state in
            let answer = state.heldAnswers.removeValue(forKey: hold)
            if answer != nil { state.cancelledAnswers += 1 }
            return answer
        }
        answer?.resume(throwing: URLError(.cancelled))
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (substitute, withholdsHead) = state.withLock { state in
            state.eventSourceRequests += 1
            return (state.nextEventSources.isEmpty ? nil : state.nextEventSources.removeFirst(), state.withholdsHeads)
        }
        let response: HTTPURLResponse
        let body: AsyncThrowingStream<Data, any Error>
        if let substitute {
            response = HTTPURLResponse(
                url: request.url!, statusCode: substitute.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            body = substitute.body
        } else {
            (response, body) = try await server.stream(request)
        }
        guard withholdsHead else { return (response, body) }

        var chunks = body.makeAsyncIterator()
        let first = try await chunks.next()
        let (relay, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        if let first { continuation.yield(first) }
        let forwarding = Task { [chunks] in
            var chunks = chunks
            do {
                while let chunk = try await chunks.next() { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return (response, relay)
    }
}
