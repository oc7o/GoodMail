/// Runs an operation one at a time.
///
/// Asking while it runs joins that run and has it go once more afterwards, so whatever prompted the request
/// isn't missed by a run that had already looked; any number of requests meanwhile share that one extra run.
/// A request that joins doesn't change what runs, so every caller passes the same operation.
@MainActor
final class SingleFlight {
    private var task: Task<Void, Never>?
    private var runsAgain = false
    /// Tells runs apart, so that a cancelled one winding down can't clear the one started after it.
    private var runs = 0

    /// Starts `operation`, or has the run under way go once more. The returned task ends after the last run.
    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let task {
            runsAgain = true
            return task
        }
        runs += 1
        let run = runs
        let task = Task {
            repeat {
                runsAgain = false
                await operation()
            } while runsAgain && !Task.isCancelled
            // Cleared in here rather than by an awaiting caller, so no caller can find a finished task.
            if runs == run { self.task = nil }
        }
        self.task = task
        return task
    }

    /// The run under way, if any, to wait for without asking for another pass.
    var current: Task<Void, Never>? {
        task
    }

    /// Cancels the run under way, if any. Its callers are let go once it has wound down, and the next request
    /// starts a new run.
    func cancel() {
        task?.cancel()
        task = nil
        runsAgain = false
    }
}
