import GoodMailCore
import SwiftUI

#if os(macOS)
/// The Mac's composer windows (D29): one per message, each opened with its composer's id and restored after a
/// relaunch from its draft row (C27). Its commands are the app's; File ▸ New Window would open a window without
/// a message.
struct ComposeScene: Scene {
    let model: AppModel

    var body: some Scene {
        WindowGroup("New Message", id: ComposeWindowRoot.windowID, for: UUID.self) { $id in
            ComposeWindowRoot(id: id)
                .environment(model)
        }
        .defaultSize(width: 760, height: 680)
        .windowToolbarStyle(.unified)
        .commandsRemoved()
    }
}

/// A composer window's content. It waits for sign-in, then finds its composer: one already open, or one restored
/// from its draft row. Signed out, it says so and offers the main window; an id without a draft closes the window.
struct ComposeWindowRoot: View {
    static let windowID = "compose"

    let id: UUID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var composer: Composer?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut:
                ContentUnavailableView {
                    Label("Sign in to GoodMail to continue writing", systemImage: "envelope.badge.shield.half.filled")
                } actions: {
                    Button("Open GoodMail") { openWindow(id: "main") }
                        .buttonStyle(.borderedProminent)
                }
            case .unavailable:
                ContentUnavailableView {
                    Label("GoodMail can't open your mail right now", systemImage: "exclamationmark.lock")
                } actions: {
                    Button("Open GoodMail") { openWindow(id: "main") }
                        .buttonStyle(.borderedProminent)
                }
            case .signedIn(let account):
                if let composer {
                    ComposeView(composer: composer)
                        .id(composer.id)
                        .environment(account)
                        .environment(\.compose, composeAction(account))
                } else {
                    ProgressView()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { model.restore() }
        .task(id: signedInAccount.map(ObjectIdentifier.init)) { await resolve() }
    }

    private var signedInAccount: MailAccount? {
        if case .signedIn(let account) = model.state { account } else { nil }
    }

    private func resolve() async {
        guard let account = signedInAccount else {
            composer = nil
            return
        }
        // A restored window may be the only one: the account still has to sync and send.
        account.start()
        guard let id, let found = await account.mail.composer(id: id) else {
            dismiss()
            return
        }
        composer = found
    }

    private func composeAction(_ account: MailAccount) -> ComposeAction {
        ComposeAction { request in
            Task {
                guard let composer = try? await account.mail.compose(request) else { return }
                openWindow(id: Self.windowID, value: composer.id)
            }
        }
    }
}
#endif

/// The composer as a sheet (iOS, §5.3): Close and Send in its bar, swiping it down keeps the draft.
struct ComposeSheet: View {
    let composer: Composer

    var body: some View {
        NavigationStack {
            ComposeView(composer: composer)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .presentationDetents([.large])
    }
}
