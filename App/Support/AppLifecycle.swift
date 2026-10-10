import Foundation
import GoodMailCore
import Synchronization

extension AppModel {
    /// The app left the screen: drafts are saved on the device and to Fastmail, the Outbox gets a pass, and on
    /// iOS released attachment copies go and the system is asked to come back for what is left (D8, D23, D35).
    func enteredBackground() {
        guard case .signedIn(let account) = state else { return }
        #if os(iOS)
        // iOS may end the app without bringing it back, so this save may be the last one (P6).
        account.commitTypedRecipients()
        Task { await TemporaryFiles.shared.purgeReleased() }
        // Asked for before the saves and the Outbox pass, which can take longer than iOS lets the app run in the
        // background; nothing after them would run then.
        BackgroundSending.schedule(
            BackgroundSending.plan(for: account.mail.outbox, hasOpenComposers: account.hasOpenComposers))
        #endif
        Task {
            await account.mail.prepareForBackground()
            BackgroundSending.schedule(for: account.mail.outbox)
        }
    }
}

extension MailAccount {
    /// Saves open composers, with what is still typed in their recipient fields, and makes one Outbox pass, but
    /// waits at most `seconds`: uploads and sending go on after that until the app is gone, and what they leave
    /// unfinished is picked up from its persisted state at the next launch.
    func prepareForQuit(waitingAtMost seconds: Double = 3) async {
        commitTypedRecipients()
        let mail = mail
        _ = await waitForWork(atMost: seconds) { await mail.prepareForBackground() }
    }
}

/// Runs `work` in a task of its own and waits until it is done, `seconds` have passed, or the waiting task is
/// cancelled, whichever comes first. Returns whether it was done.
///
/// The work itself isn't stopped. A task group won't do here: it waits for every child even after cancelling
/// it, and the Outbox's flush and uploads don't stop for a cancelled caller (a step may be half way through a
/// request).
@MainActor
func waitForWork(atMost seconds: Double? = nil, _ work: @escaping @MainActor () async -> Void) async -> Bool {
    let gate = WaitGate()
    Task {
        await work()
        gate.open(true)
    }
    let timer = seconds.map { seconds in
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            gate.open(false)
        }
    }
    let isDone = await withTaskCancellationHandler {
        await gate.wait()
    } onCancel: {
        gate.open(false)
    }
    timer?.cancel()
    return isDone
}

/// Opens once, from any thread, with whether the work was done; whoever waits gets that, before or after.
private final class WaitGate: Sendable {
    private struct State {
        var result: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    func open(_ result: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}
