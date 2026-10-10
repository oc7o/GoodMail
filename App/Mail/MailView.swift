import GoodMailCore
import JMAPKit
import SwiftUI

/// The signed-in app: mailboxes, the list for the selected one, and the reading pane, with the Undo banner and
/// the Outbox's notices over them (§5.6). Composers open from here: windows on the Mac, sheets on iOS.
struct MailView: View {
    @Bindable var model: MailModel
    @State private var presenter: ComposePresenter
    @State private var undoReport: String?
    @Environment(MailAccount.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// - Parameter presenter: How composers are shown; the render harness passes its own.
    init(model: MailModel, presenter: ComposePresenter = ComposePresenter()) {
        self.model = model
        _presenter = State(initialValue: presenter)
    }

    var body: some View {
        @Bindable var account = account
        let compose = presenter.action(for: model)
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            switch model.destination {
            case .maskedEmail:
                MaskedEmailListView(model: model)
            case .outbox:
                OutboxView(model: model)
            default:
                ThreadListView(model: model)
            }
        } detail: {
            switch model.destination {
            case .maskedEmail:
                if let id = model.selectedMaskedEmailID, let masked = model.maskedEmails.first(where: { $0.id == id }) {
                    MaskedEmailDetailView(model: model, masked: masked)
                        .id(id)
                } else {
                    ContentUnavailableView("No Address Selected", systemImage: "theatermasks")
                }
            case .outbox:
                ContentUnavailableView(
                    "Outbox", systemImage: "tray.and.arrow.up",
                    description: Text("Messages go out as soon as Fastmail can take them."))
            default:
                if let id = model.selectedThreadID {
                    ThreadView(model: model, threadID: id)
                        .id(id)
                } else {
                    ContentUnavailableView("No Conversation Selected", systemImage: "envelope.open")
                }
            }
        }
        .environment(\.compose, compose)
        .focusedSceneValue(\.composeAction, compose)
        .overlay(alignment: .bottom) {
            SendBanner(account: account, undo: undo) { model.destination = .outbox }
        }
        .overlay(alignment: .top) {
            OutboxNotices(outbox: model.outbox)
        }
        .sheet(item: $presenter.sheet) { composer in
            ComposeSheet(composer: composer)
                .environment(account)
        }
        .sheet(isPresented: $account.isCreatingMaskedEmail) {
            MaskedEmailEditor(model: model)
        }
        .alert(presenter.problem?.title ?? "", isPresented: isShowingProblem, presenting: presenter.problem) { problem in
            if case .inlineForwardIncomplete(let emailID) = problem {
                Button("Forward as Attachment") { compose(.forward(emailID: emailID, asAttachment: true)) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(problem.message)
        }
        .alert("Undo Send", isPresented: Binding(get: { undoReport != nil }, set: { if !$0 { undoReport = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoReport ?? "")
        }
        .task {
            #if os(macOS)
            if presenter.showWindow == nil {
                let openWindow = openWindow
                presenter.showWindow = { openWindow(id: ComposeWindowRoot.windowID, value: $0.id) }
            }
            #endif
            account.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.resumePush()
            Task { await model.refresh() }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(get: { presenter.problem != nil }, set: { if !$0 { presenter.problem = nil } })
    }

    private func undo(_ id: UUID) {
        Task { undoReport = await presenter.undo(id, in: model) }
    }
}

/// The banner at the bottom after Send: Undo for ten seconds (D12), or, for a message that waits for a
/// connection, when it will go out (§3.10).
struct SendBanner: View {
    let account: MailAccount
    let undo: (UUID) -> Void
    let openOutbox: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Group {
                if let undoable = Self.undoable(account.mail.outbox.undoable, at: context.date) {
                    UndoSendBanner(subject: undoable.subject, undoUntil: undoable.undoUntil) { undo(undoable.id) }
                        .id(undoable.id)
                } else if let waiting = account.messageWaitingOffline(at: context.date) {
                    UndoSendBanner(subject: waiting.subject, undoUntil: waiting.at, isOffline: true, onUndo: {},
                                   onOpenOutbox: openOutbox)
                        .id(waiting.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Self.bottomInset)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Clear of the bottom toolbar an iPhone's list and conversation have.
    #if os(iOS)
    static let bottomInset: CGFloat = 64
    #else
    static let bottomInset: CGFloat = 16
    #endif

    /// The Outbox's Undo offer until its time is up; the Outbox itself lets go of it a little later.
    static func undoable(_ offer: Outbox.UndoableSend?, at date: Date) -> Outbox.UndoableSend? {
        guard let offer, offer.undoUntil > date else { return nil }
        return offer
    }
}

/// One-off news from the Outbox, as short glass toasts at the top (§5.6).
struct OutboxNotices: View {
    let outbox: Outbox

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(outbox.notices) { notice in
                    Label(Self.text(of: notice), systemImage: Self.symbol(of: notice))
                        .font(.callout)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .onTapGesture { outbox.dismiss(notice) }
                        .task {
                            try? await Task.sleep(for: .seconds(5))
                            outbox.dismiss(notice)
                        }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: 560)
        .animation(.snappy, value: outbox.notices)
    }

    static func text(of notice: Outbox.Notice) -> String {
        switch notice {
        case .sentElsewhere(let subject): "“\(OutboxRow.subject(subject))” was sent from another device"
        case .canceledElsewhere(let subject): "Sending “\(OutboxRow.subject(subject))” was canceled on another device"
        case .alreadySent(let subject): "“\(OutboxRow.subject(subject))” was already sent"
        case .canceled(let subject): "Sending “\(OutboxRow.subject(subject))” was canceled"
        }
    }

    private static func symbol(of notice: Outbox.Notice) -> String {
        switch notice {
        case .sentElsewhere, .alreadySent: "paperplane"
        case .canceledElsewhere, .canceled: "arrow.uturn.backward"
        }
    }
}
