import Foundation
import GoodMailCore
import Synchronization
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Keeps mail going out while GoodMail isn't in front (D35).
///
/// - Every flush, upload and submission runs inside `makeActivity()`'s activity: on iOS a background task, which
///   buys the time to finish what was started; on the Mac a process activity, so App Nap doesn't stall it.
/// - When iOS sends the app to the background with work left, it asks for an app-refresh task, and for a
///   processing task that needs a network while messages wait. Both run `AppModel.sendInBackground()` when iOS
///   decides; the identifiers are permitted in `Config/GoodMail-Info.plist`.
/// - A Send with more than 5 MB still to upload asks for a continued-processing task, which iOS shows with the
///   upload's progress and lets run on after the user leaves the app.
@MainActor
enum BackgroundSending {
    static let refreshTaskID = "dev.goodmail.GoodMail.outbox-refresh"
    static let processingTaskID = "dev.goodmail.GoodMail.outbox-processing"
    /// Continued-processing tasks: this prefix and a suffix of their own. The Info.plist permits `send.*`, and
    /// iOS kills an app that registers one identifier twice, so every request gets a fresh one.
    static let sendTaskPrefix = "dev.goodmail.GoodMail.send."
    static let continuedProcessingThreshold = 5_000_000

    static func makeActivity() -> any BackgroundActivity {
        #if os(iOS)
        UIKitBackgroundActivity()
        #else
        ProcessInfoActivity()
        #endif
    }

    /// Asks iOS to wake the app for the outbox's work while there is any.
    static func schedule(for outbox: Outbox) {
        #if os(iOS)
        guard outbox.hasPendingWork else { return }
        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        var requests: [BGTaskRequest] = [refresh]
        let waits = outbox.items.contains { item in
            switch item.state {
            case .waiting, .sending, .cancelling: true
            case .held, .failed: false
            }
        }
        if waits {
            // Uploads and submissions need the network, but not power: mail should go out on battery too.
            let processing = BGProcessingTaskRequest(identifier: processingTaskID)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            requests.append(processing)
        }
        submit(requests)
        #endif
    }

    static func cancelScheduledWork() {
        #if os(iOS)
        BGTaskScheduler.shared.cancelAllTaskRequests()
        #endif
    }

    #if os(iOS)
    /// Submitting may wait for the scheduler, which wants that off the main thread.
    private static func submit(_ requests: [BGTaskRequest]) {
        let requests = requests.map(UncheckedSendable.init)
        Task.detached(priority: .utility) {
            for request in requests {
                try? await BGTaskScheduler.shared.submitTaskRequest(request.value)
            }
        }
    }

    /// For a Send with a lot still to upload: a continued-processing task that shows the upload's progress
    /// until the message is on Fastmail (held), has failed, or is gone from the Outbox (sent, or undone).
    static func continueSending(_ id: UUID, subject: String, outbox: Outbox) {
        let identifier = sendTaskPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { @Sendable task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let running = UncheckedSendable(task)
            Task { @MainActor in await follow(running.value, sending: id, outbox: outbox) }
        }
        guard registered else { return }
        let title = subject.trimmingCharacters(in: .whitespaces).isEmpty ? "Sending your message" : "Sending “\(subject)”"
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title, subtitle: "Uploading attachments")
        submit([request])
    }

    private static func follow(_ task: BGContinuedProcessingTask, sending id: UUID, outbox: Outbox) async {
        let progress = task.progress
        progress.totalUnitCount = 1000
        let expired = Flag()
        task.expirationHandler = { @Sendable in expired.set() }
        var succeeded = false
        while !expired.isSet {
            guard let item = outbox.items.first(where: { $0.id == id }) else {
                succeeded = true
                break
            }
            if case .held = item.state {
                succeeded = true
                break
            }
            if case .failed = item.state { break }
            if let fraction = outbox.uploadProgress(for: id) {
                progress.completedUnitCount = Int64(fraction * 1000)
            } else if case .sending = item.state {
                progress.completedUnitCount = 990
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if succeeded { progress.completedUnitCount = 1000 }
        task.setTaskCompleted(success: succeeded)
    }
    #endif
}

#if os(iOS)
/// `beginBackgroundTask`: time to finish a flush, an upload or a submission after the app left the screen.
@MainActor
final class UIKitBackgroundActivity: BackgroundActivity {
    func begin(_ reason: String) -> @MainActor () -> Void {
        let token = BackgroundTaskToken()
        // iOS calls the expiration handler on the main thread when the time is up; the task must end then.
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: reason) { token.end() }
        return { token.end() }
    }
}

@MainActor
private final class BackgroundTaskToken {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#else
/// A process activity, so that App Nap doesn't slow down mail being sent while GoodMail is in the background.
@MainActor
final class ProcessInfoActivity: BackgroundActivity {
    func begin(_ reason: String) -> @MainActor () -> Void {
        let token = ProcessActivityToken(
            ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: reason))
        return { token.end() }
    }
}

@MainActor
private final class ProcessActivityToken {
    private var activity: (any NSObjectProtocol)?

    init(_ activity: any NSObjectProtocol) {
        self.activity = activity
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
#endif

/// Set once, from any thread.
private final class Flag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() {
        value.withLock { $0 = true }
    }
}

/// A value of a type the SDK doesn't mark `Sendable` but that is safe to hand over here: the scheduler's requests
/// and tasks, used by one task at a time.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
