import Foundation
import Network

/// The time the outbox and composers go by: every Undo window, hold check, retry and autosave is a deadline on
/// this clock, never one the server named (C15). Tests use a manual clock shared with the demo server.
public protocol OutboxClock: Sendable {
    var now: Date { get }
    /// Returns once `now` has reached `date`; throws `CancellationError` when the task is cancelled first.
    func sleep(until date: Date) async throws
}

public struct SystemOutboxClock: OutboxClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until date: Date) async throws {
        // The device may sleep or its clock may be set meanwhile, so the remaining time is measured again.
        while case let remaining = date.timeIntervalSinceNow, remaining > 0 {
            try await Task.sleep(for: .seconds(min(remaining, 60)))
        }
        try Task.checkCancellation()
    }
}

/// What the device's network connection allows.
public struct NetworkPath: Sendable, Equatable {
    public var isSatisfied: Bool
    /// Cellular or a personal hotspot.
    public var isExpensive: Bool
    /// Low Data Mode, which prefetching respects.
    public var isConstrained: Bool

    public init(isSatisfied: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public protocol NetworkPathSource: Sendable {
    /// The current path, then every change, until the iteration ends.
    func paths() -> AsyncStream<NetworkPath>
}

/// The device's network path, from `NWPathMonitor`.
public struct SystemNetworkPath: NetworkPathSource {
    public init() {}

    public func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPath(
                    isSatisfied: path.status == .satisfied, isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.goodmail.network-path"))
        }
    }
}

@MainActor
public protocol BackgroundActivity: AnyObject {
    /// Asks the OS to keep the app running for `reason`; the returned closure ends it. iOS: beginBackgroundTask.
    func begin(_ reason: String) -> @MainActor () -> Void
}

/// For hosts that keep running anyway, and for tests.
@MainActor
public final class NoBackgroundActivity: BackgroundActivity {
    public init() {}

    public func begin(_ reason: String) -> @MainActor () -> Void {
        {}
    }
}
