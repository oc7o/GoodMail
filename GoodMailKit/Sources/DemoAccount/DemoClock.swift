import Foundation
import Synchronization

/// The demo server's time: the system clock, or, for tests, a clock that only moves when told to.
///
/// Everything time-dependent in `DemoTransport` reads it: when mail arrives, when uploads expire, when held
/// messages go out. Tests share one manual clock between the server and the code under test, so that an Undo
/// window or a hold passes in an instant and always the same way.
public final class DemoClock: Sendable {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
        /// Wakes the waiter on a clock that follows the system clock.
        var timer: Task<Void, Never>?
    }

    private struct WeakObserver {
        weak var value: (any DemoClockObserver)?
    }

    private struct State {
        /// The time of a manual clock; `nil` for one that follows the system clock.
        var manualNow: Date?
        /// How far `advance(by:)` moved a clock that follows the system clock.
        var offset: TimeInterval = 0
        var waiters: [UUID: Waiter] = [:]
        var observers: [WeakObserver] = []

        var now: Date { manualNow ?? Date.now.addingTimeInterval(offset) }
    }

    private let state: Mutex<State>

    /// Follows the system clock, as in the app's demo mode.
    public init() {
        state = Mutex(State())
    }

    /// Stands at `manualStart` until `advance(by:)` moves it.
    public init(manualStart: Date) {
        state = Mutex(State(manualNow: manualStart))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    /// Whether time only moves through `advance(by:)`.
    public var isManual: Bool {
        state.withLock { $0.manualNow != nil }
    }

    /// Moves the clock forward.
    ///
    /// What falls due happens before this returns: the demo servers on this clock release the messages they
    /// held until then, and then the `wait(until:)` calls that are due resume.
    public func advance(by seconds: TimeInterval) {
        precondition(seconds >= 0, "Time only moves forward")
        let observers = state.withLock { state in
            if let now = state.manualNow {
                state.manualNow = now.addingTimeInterval(seconds)
            } else {
                state.offset += seconds
            }
            state.observers.removeAll { $0.value == nil }
            return state.observers.compactMap(\.value)
        }
        for observer in observers { observer.clockAdvanced() }
        let due = state.withLock { state in
            let now = state.now
            let ids = state.waiters.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
            return ids.compactMap { state.waiters.removeValue(forKey: $0.key) }
        }
        for waiter in due {
            waiter.timer?.cancel()
            waiter.continuation.resume()
        }
    }

    /// Returns once the clock reached `date`, or as soon as the task is cancelled.
    ///
    /// A manual clock gets there only through `advance(by:)`; one that follows the system clock also by itself.
    public func wait(until date: Date) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (isDue, isManual) = state.withLock { state in
                    // Checked under the lock, so a cancellation handler that ran before this finds the flag set.
                    guard state.now < date, !Task.isCancelled else { return (true, state.manualNow != nil) }
                    state.waiters[id] = Waiter(deadline: date, continuation: continuation)
                    return (false, state.manualNow != nil)
                }
                if isDue {
                    continuation.resume()
                } else if !isManual {
                    startTimer(for: id, until: date)
                }
            }
        } onCancel: {
            resume(id)
        }
    }

    private func startTimer(for id: UUID, until date: Date) {
        let timer = Task { [weak self] in
            while let self, !Task.isCancelled {
                let remaining = date.timeIntervalSince(now)
                guard remaining > 0 else { return resume(id) }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
        let isWaiting = state.withLock { state in
            guard state.waiters[id] != nil else { return false }
            state.waiters[id]?.timer = timer
            return true
        }
        if !isWaiting { timer.cancel() }
    }

    private func resume(_ id: UUID) {
        guard let waiter = state.withLock({ $0.waiters.removeValue(forKey: id) }) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume()
    }

    /// Has `observer` hear of every `advance(by:)` for as long as it exists.
    func addObserver(_ observer: any DemoClockObserver) {
        state.withLock { $0.observers.append(WeakObserver(value: observer)) }
    }
}

/// Something that acts when a `DemoClock` is advanced, before that call returns.
protocol DemoClockObserver: AnyObject, Sendable {
    func clockAdvanced()
}
