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
    @Environment(\.scenePhase) private var scenePhase

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
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("GoodMail Can't Open Your Mail", systemImage: "exclamationmark.lock")
                } description: {
                    Text(reason + " Nothing was deleted.")
                } actions: {
                    Button("Try Again") { model.retryRestore() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Say, the device was locked when a background task started the app.
            if phase == .active, case .unavailable = model.state { model.retryRestore() }
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
