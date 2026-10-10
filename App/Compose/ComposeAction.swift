import GoodMailCore
import JMAPKit
import MailCompose
import SwiftUI

/// Opens a composer for a request: a window of its own on the Mac (D29), a sheet on iOS. Views get it from the
/// environment; iOS menu commands get the focused scene's.
struct ComposeAction: Sendable {
    private let handler: @MainActor (ComposeRequest) -> Void

    init(_ handler: @escaping @MainActor (ComposeRequest) -> Void) {
        self.handler = handler
    }

    @MainActor func callAsFunction(_ request: ComposeRequest) {
        handler(request)
    }
}

extension EnvironmentValues {
    @Entry var compose = ComposeAction { _ in }
}

extension FocusedValues {
    /// The compose action of the window in front: New Message on iOS, where composers are sheets of a window.
    @Entry var composeAction: ComposeAction?
}

/// What one main window shows of composing: the composer sheet (iOS) and a request that couldn't be opened.
@MainActor
@Observable
final class ComposePresenter {
    /// iOS: the composer in the sheet.
    var sheet: Composer?
    var problem: ComposeProblem?
    /// How a composer is shown on the Mac: `openWindow` in the app; the render harness puts it on a stage.
    @ObservationIgnored var showWindow: ((Composer) -> Void)?

    func open(_ request: ComposeRequest, in mail: MailModel) {
        Task {
            do {
                present(try await mail.compose(request))
            } catch SendProblem.inlineForwardIncomplete {
                guard case .forward(let emailID, _) = request else { return }
                problem = .inlineForwardIncomplete(emailID: emailID)
            } catch {
                problem = .failed(error.localizedDescription)
            }
        }
    }

    func present(_ composer: Composer) {
        #if os(iOS)
        sheet = composer
        #else
        showWindow?(composer)
        #endif
    }

    /// Undo in the banner: the message comes back in its composer (D12). Returns what to tell when it couldn't.
    func undo(_ id: UUID, in mail: MailModel) async -> String? {
        switch await mail.outbox.cancel(id) {
        case .backToDrafts:
            open(.restore(id), in: mail)
            return nil
        case .requested:
            return nil
        case .alreadySent:
            return "The message was already sent."
        case .unreachable(let time):
            return OutboxActions.unreachable(sendsAround: time)
        }
    }

    func action(for mail: MailModel) -> ComposeAction {
        ComposeAction { [weak self] request in self?.open(request, in: mail) }
    }
}

enum ComposeProblem: Identifiable {
    /// The original of an inline forward isn't complete here (C20); forwarding it as an attachment works.
    case inlineForwardIncomplete(emailID: String)
    case failed(String)

    var id: String {
        switch self {
        case .inlineForwardIncomplete(let emailID): "forward:" + emailID
        case .failed(let message): "failed:" + message
        }
    }

    var title: String {
        switch self {
        case .inlineForwardIncomplete: "Forward as Attachment?"
        case .failed: "Couldn't Open the Message"
        }
    }

    var message: String {
        switch self {
        case .inlineForwardIncomplete: SendProblem.inlineForwardIncomplete.localizedDescription
        case .failed(let message): message
        }
    }
}

extension MailAccount {
    /// Turns an inline forward that can't be sent (its original is incomplete here, C20) into a forward as an
    /// attachment, keeping what was written, and returns it; the inline one is deleted.
    func forwardAsAttachment(instead composer: Composer) async -> Composer? {
        guard let original = composer.draft.original?.emailID,
              let replacement = try? await mail.compose(.forward(emailID: original, asAttachment: true))
        else { return nil }
        replacement.to = composer.to
        replacement.cc = composer.cc
        replacement.bcc = composer.bcc
        replacement.body = composer.body
        _ = await composer.discard()
        return replacement
    }
}
