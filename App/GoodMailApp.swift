import GoodMailCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct GoodMailApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(GoodMailAppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }
    #else
    @State private var model = AppModel()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Decrypted copies that a crash or a kill left behind, and the files system components put there (C32).
        TemporaryFiles.purgeContainerTemporaryDirectory()
    }

    var body: some Scene {
        let model = model
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .task { model.restore() }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif
        .commands { MailCommands(model: model) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.enteredBackground() }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundSending.refreshTaskID)) { await model.sendInBackground() }
        .backgroundTask(.processingTask(BackgroundSending.processingTaskID)) { await model.sendInBackground() }
        #endif

        #if os(macOS)
        ComposeScene(model: model)
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut:
                OnboardingView()
            case .signedIn(let account):
                MailView(model: account.mail)
                    .environment(account)
            }
        }
        .alert("GoodMail Started a New Local Copy", isPresented: isShowingStoreAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("GoodMail couldn't open its local copy and started a new one. The old copy is kept.")
        }
    }

    private var isShowingStoreAlert: Binding<Bool> {
        Binding(get: { model.storeWasMovedAside }, set: { if !$0 { model.storeWasMovedAside = false } })
    }
}

extension AppModel {
    /// The app left the screen: drafts are saved on the device and to Fastmail, the Outbox gets a pass, and on
    /// iOS released attachment copies go and the system is asked to come back for what is left (D8, D23, D35).
    func enteredBackground() {
        guard case .signedIn(let account) = state else { return }
        #if os(iOS)
        Task { await TemporaryFiles.shared.purgeReleased() }
        #endif
        Task {
            await account.mail.prepareForBackground()
            BackgroundSending.schedule(for: account.mail.outbox)
        }
    }
}

#if os(macOS)
/// Quitting: open drafts are saved first (for a few seconds at most), then every decrypted attachment copy is
/// deleted (D23).
@MainActor
final class GoodMailAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard case .signedIn(let account) = model.state else {
            TemporaryFiles.shared.purgeAllNow()
            return .terminateNow
        }
        Task {
            await account.prepareForQuit()
            TemporaryFiles.shared.purgeAllNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

extension MailAccount {
    /// Saves open composers, with what is still typed in their recipient fields, and makes one Outbox pass, but
    /// waits at most `seconds`.
    func prepareForQuit(waitingAtMost seconds: Double = 3) async {
        commitTypedRecipients()
        let mail = mail
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await mail.prepareForBackground() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }
}
