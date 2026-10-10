import Foundation

/// One serial queue per draft (C5): saves, uploads waited for, the send and its cleanup, verification,
/// finalizing, cancel and discard of one composition run strictly one after another, each looking at the row
/// afresh when its turn comes. Different drafts don't wait for each other.
@MainActor
final class OutboxChannels {
    private struct Tail {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var tails: [String: Tail] = [:]
    private var cancellers: [UUID: () -> Void] = [:]

    /// Queues `operation` on `key` right away, to run once everything queued before it has finished.
    ///
    /// Cancelling a caller waiting for the returned task doesn't cancel the operation, which may be half way
    /// through a server request; `cancelAll()` does.
    @discardableResult
    func enqueue<T: Sendable>(
        _ key: String, _ operation: @escaping @MainActor () async throws -> T
    ) -> Task<T, any Error> {
        let previous = tails[key]?.task
        let token = UUID()
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        cancellers[token] = { task.cancel() }
        tails[key] = Tail(token: token, task: Task { @MainActor [weak self] in
            _ = await task.result
            self?.cancellers[token] = nil
            if self?.tails[key]?.token == token { self?.tails[key] = nil }
        })
        return task
    }

    /// Runs `operation` once everything queued before on `key` has finished, and returns its result.
    func run<T: Sendable>(_ key: String, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await enqueue(key, operation).value
    }

    /// Waits until every operation queued so far, and any queued meanwhile, has finished.
    func idle() async {
        while let tail = tails.values.first {
            await tail.task.value
        }
    }

    func cancelAll() {
        for cancel in cancellers.values { cancel() }
    }
}
