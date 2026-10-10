import GoodMailCore
import SwiftUI

/// The message Reply, Reply All and Forward act on in the window in front (§5.8).
struct ReplyTarget {
    let emailID: String
    let compose: ComposeAction
}

extension FocusedValues {
    @Entry var replyTarget: ReplyTarget?
}

/// The menu commands, with Apple Mail's shortcuts (D30, C27):
/// - File: New Message ⌘N in place of New Window, New Viewer Window ⌥⌘N, New Masked Email ⌃⌘N (was ⌘N).
/// - Message: Send ⇧⌘D, Reply ⌘R, Reply All ⇧⌘R, Forward ⇧⌘F.
/// - Mailbox: Get New Mail ⇧⌘N (was ⌘R).
/// - Format: bold, italic, underline (⌘B, ⌘I, ⌘U) for the composer's editor; on the Mac also Import from iPhone.
struct MailCommands: Commands {
    let model: AppModel

    @FocusedValue(\.replyTarget) private var replyTarget
    @FocusedValue(\.composeFlow) private var composeFlow
    @FocusedValue(\.composeAction) private var sceneCompose
    @FocusedValue(\.mainWindow) private var mainWindow
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message", action: newMessage)
                .keyboardShortcut("n")
                .disabled(!canCompose)
            #if os(macOS)
            Button("New Viewer Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.option, .command])
            #endif
            Button("New Masked Email", action: newMaskedEmail)
                .keyboardShortcut("n", modifiers: [.control, .command])
                .disabled(account == nil || mainWindow == nil)
        }
        CommandMenu("Message") {
            Button("Send") { composeFlow?.sendNow() }
                .keyboardShortcut("d", modifiers: [.shift, .command])
                .disabled(composeFlow?.canSend != true)
            Divider()
            Button("Reply") { replyTarget.map { $0.compose(.reply(emailID: $0.emailID, all: false)) } }
                .keyboardShortcut("r")
                .disabled(replyTarget == nil)
            Button("Reply All") { replyTarget.map { $0.compose(.reply(emailID: $0.emailID, all: true)) } }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(replyTarget == nil)
            Button("Forward") { replyTarget.map { $0.compose(.forward(emailID: $0.emailID, asAttachment: false)) } }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(replyTarget == nil)
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") {
                guard let account else { return }
                Task { await account.mail.refresh() }
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            .disabled(account == nil)
        }
        TextFormattingCommands()
        #if os(macOS)
        ImportFromDevicesCommands()
        #endif
    }

    private var account: MailAccount? {
        if case .signedIn(let account) = model.state { account } else { nil }
    }

    private var canCompose: Bool {
        #if os(macOS)
        account != nil
        #else
        sceneCompose != nil
        #endif
    }

    /// On the Mac a composer window opens from anywhere, a composer window in front included; on iOS the
    /// window in front shows it as a sheet.
    private func newMessage() {
        #if os(macOS)
        guard let account else { return }
        let openWindow = openWindow
        Task {
            guard let composer = try? await account.mail.compose(.new()) else { return }
            openWindow(id: ComposeWindowRoot.windowID, value: composer.id)
        }
        #else
        sceneCompose?(.new())
        #endif
    }

    /// In the main window in front only: every window would otherwise show the sheet.
    private func newMaskedEmail() {
        guard let account else { return }
        mainWindow?.newMaskedEmail(in: account.mail)
    }
}
