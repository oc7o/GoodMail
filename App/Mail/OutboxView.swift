import GoodMailCore
import JMAPKit
import SwiftUI

/// The Outbox (§5.6): messages waiting, being sent or held for Undo, those that failed, and drafts written here
/// that Fastmail doesn't have yet. What a row offers depends on its state (C3): nothing that might go out is
/// deleted without being cancelled first, and Cancel is offered only while it can still work.
struct OutboxView: View {
    let model: MailModel

    @Environment(\.compose) private var compose
    @State private var isReplacingToken = false
    @State private var report: String?
    @State private var deleting: Outbox.Item?
    @State private var deletingDraft: Outbox.DraftSummary?

    var body: some View {
        let outbox = model.outbox
        let actions = OutboxActions(outbox: outbox, compose: compose) { report = $0 }
        List {
            ForEach(OutboxSection.allCases) { section in
                let items = outbox.items.filter { OutboxSection(of: $0.state) == section }
                if !items.isEmpty {
                    Section(section.title) {
                        ForEach(items) { item in
                            OutboxRow(item: item, isOnline: model.isOnline,
                                      tokenCanSend: model.sendAvailability == .available, actions: actions,
                                      replaceToken: { isReplacingToken = true }, delete: { deleting = item })
                        }
                    }
                }
            }
            if !outbox.unsyncedDrafts.isEmpty {
                Section("Drafts on This Device") {
                    ForEach(outbox.unsyncedDrafts) { draft in
                        OutboxDraftRow(draft: draft, actions: actions) { deletingDraft = draft }
                    }
                }
            }
            #if os(iOS)
            if outbox.hasPendingWork {
                Section {
                } footer: {
                    Text(OutboxView.backgroundNote)
                }
            }
            #endif
        }
        .overlay {
            if outbox.items.isEmpty && outbox.unsyncedDrafts.isEmpty {
                ContentUnavailableView(
                    "Nothing to Send", systemImage: "tray.and.arrow.up",
                    description: Text("Messages waiting to be sent, and drafts not on Fastmail yet, appear here."))
            }
        }
        .navigationTitle("Outbox")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        #endif
        .sheet(isPresented: $isReplacingToken) { ReplaceTokenView() }
        .alert("Outbox", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(report ?? "")
        }
        .confirmationDialog(
            "Delete “\(OutboxRow.subject(deleting?.subject ?? ""))”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { item in
            Button("Delete Message", role: .destructive) { Task { await actions.delete(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It won't be sent, and its copy in Drafts goes to Trash.")
        }
        .confirmationDialog(
            "Delete “\(OutboxRow.subject(deletingDraft?.subject ?? ""))”?",
            isPresented: Binding(get: { deletingDraft != nil }, set: { if !$0 { deletingDraft = nil } }),
            titleVisibility: .visible, presenting: deletingDraft
        ) { draft in
            Button("Delete Draft", role: .destructive) { Task { await actions.delete(draft) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(OutboxDraftRow.deleteWarning)
        }
    }

    static let backgroundNote = "Waiting messages go out while GoodMail runs; iOS may also send them in the background."
}

/// The Outbox in numbers, for the pill under the thread list: messages not out yet, and those that failed.
struct OutboxCounts {
    var waiting = 0
    var failed = 0

    @MainActor init(_ outbox: Outbox) {
        for item in outbox.items {
            switch item.state {
            case .waiting, .sending, .cancelling: waiting += 1
            case .failed: failed += 1
            case .held: break
            }
        }
    }
}

enum OutboxSection: CaseIterable, Identifiable {
    case waiting, sending, failed

    init(of state: Outbox.State) {
        switch state {
        case .waiting: self = .waiting
        case .sending, .cancelling, .held: self = .sending
        case .failed: self = .failed
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .sending: "Sending"
        case .failed: "Failed"
        }
    }
}

/// What the Outbox's buttons do, outside the view; the render harness drives it too.
@MainActor
struct OutboxActions {
    let outbox: Outbox
    let compose: ComposeAction
    let report: @MainActor (String) -> Void

    /// Cancel: a waiting or failed message is a draft again; one being sent is cancelled once its outcome is
    /// known; a held one is cancelled on Fastmail while the deadline allows.
    func cancel(_ item: Outbox.Item) async {
        tell(await outbox.cancel(item.id), subject: item.subject)
    }

    /// Edit: out of the queue and back in a composer.
    func edit(_ item: Outbox.Item) async {
        if case .failed = item.state {
            compose(.restore(item.id))
            return
        }
        let outcome = await outbox.cancel(item.id)
        if outcome == .backToDrafts {
            compose(.restore(item.id))
        } else {
            tell(outcome, subject: item.subject)
        }
    }

    func delete(_ item: Outbox.Item) async {
        switch await outbox.discard(item.id) {
        case .discarded, .requested: break
        case .alreadySent: report("“\(OutboxRow.subject(item.subject))” was already sent.")
        case .unreachable(let time): report(Self.unreachable(sendsAround: time))
        }
    }

    func retry(_ item: Outbox.Item) {
        outbox.retry(item.id)
    }

    func open(_ draft: Outbox.DraftSummary) {
        compose(.restore(draft.id))
    }

    func delete(_ draft: Outbox.DraftSummary) async {
        _ = await outbox.discard(draft.id)
    }

    private func tell(_ outcome: Outbox.CancelOutcome, subject: String) {
        switch outcome {
        case .backToDrafts, .requested: break
        case .alreadySent: report("“\(OutboxRow.subject(subject))” was already sent.")
        case .unreachable(let time): report(Self.unreachable(sendsAround: time))
        }
    }

    static func unreachable(sendsAround time: Date) -> String {
        "Couldn't reach Fastmail – it goes out at about \(time.formatted(date: .omitted, time: .standard))."
    }
}

/// One message of the Outbox: subject, recipients, what is happening to it, and what can be done.
struct OutboxRow: View {
    let item: Outbox.Item
    let isOnline: Bool
    /// Whether the account's token may send now, for a message that failed because an earlier one couldn't.
    var tokenCanSend = false
    let actions: OutboxActions
    var replaceToken: () -> Void = {}
    var delete: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // The buttons go under the text when the column is too narrow for both side by side.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    summary(now: context.date)
                    Spacer(minLength: 8)
                    buttons(now: context.date)
                }
                VStack(alignment: .leading, spacing: 6) {
                    summary(now: context.date)
                    buttons(now: context.date)
                        .padding(.leading, 30)
                }
            }
            .padding(.vertical, 4)
            .contextMenu {
                ForEach(Self.offeredActions(for: item.state, now: context.date, isOnline: isOnline,
                                            tokenCanSend: tokenCanSend), id: \.self) {
                    button($0)
                }
            }
        }
    }

    private func summary(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.subject(item.subject))
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !item.recipients.isEmpty {
                    Text("To: " + RecipientField.summary(of: item.recipients))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(Self.status(of: item.state, now: now, tokenCanSend: tokenCanSend))
                    .font(.subheadline)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(now: Date) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.offeredActions(for: item.state, now: now, isOnline: isOnline, tokenCanSend: tokenCanSend),
                    id: \.self) { action in
                button(action)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func button(_ action: Action) -> some View {
        Button(action.title, role: action == .delete ? .destructive : nil) {
            switch action {
            case .cancel: Task { await actions.cancel(item) }
            case .edit: Task { await actions.edit(item) }
            case .delete: delete()
            case .retry: actions.retry(item)
            case .replaceToken: replaceToken()
            }
        }
    }

    enum Action: Hashable {
        case cancel, edit, delete, retry, replaceToken

        var title: String {
            switch self {
            case .cancel: "Cancel"
            case .edit: "Edit"
            case .delete: "Delete"
            case .retry: "Retry"
            case .replaceToken: "Replace Token…"
            }
        }
    }

    /// The table in §5.6: nothing is offered for a message being cancelled, Cancel for a held one only before
    /// its deadline, and Delete for a held one only online, since it has to be cancelled on Fastmail first. A
    /// message that failed because the token couldn't send offers Replace Token… until the token can.
    static func offeredActions(
        for state: Outbox.State, now: Date, isOnline: Bool, tokenCanSend: Bool = false
    ) -> [Action] {
        switch state {
        case .waiting: [.cancel, .edit, .delete]
        case .sending: [.cancel]
        case .cancelling: []
        case .held(_, let sendsAround):
            (now < cancelDeadline(sendsAround: sendsAround) ? [.cancel] : []) + (isOnline ? [.delete] : [])
        case .failed(.tokenLacksSubmission) where !tokenCanSend: [.replaceToken, .edit, .delete]
        case .failed: [.edit, .retry, .delete]
        }
    }

    /// Cancel is offered until 13 s after the submission started; Fastmail sends from 15 s on.
    static func cancelDeadline(sendsAround: Date) -> Date {
        sendsAround.addingTimeInterval(Outbox.cancelDeadline - TimeInterval(Outbox.holdSeconds))
    }

    static func status(of state: Outbox.State, now: Date, tokenCanSend: Bool = false) -> String {
        switch state {
        case .failed(.tokenLacksSubmission) where tokenCanSend: "Not sent: the API token couldn't send mail then."
        case .waiting(.offline): "Waiting for connection"
        case .waiting(.uploading(let fraction)):
            fraction.map { "Uploading attachments – \(Int(($0 * 100).rounded())) %" } ?? "Uploading attachments"
        case .waiting(.retry(let at)) where at > now: "Fastmail is busy, retrying at \(time(at))"
        case .waiting(.retry): "Waiting to be sent"
        case .waiting(.localUndo(let until)): "Sending at about \(time(until, seconds: true))"
        case .waiting(.unknownAccount): "Waiting for Fastmail"
        case .sending: "Sending…"
        case .cancelling: "Cancelling…"
        case .held(_, let sendsAround): "Sending at about \(time(sendsAround, seconds: true))"
        case .failed(let failure): failure.localizedDescription
        }
    }

    private static func time(_ date: Date, seconds: Bool = false) -> String {
        date.formatted(seconds ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
    }

    static func subject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No Subject" : trimmed
    }

    private var isFailed: Bool {
        if case .failed = item.state { true } else { false }
    }

    private var symbol: String {
        switch item.state {
        case .waiting(.offline): "wifi.slash"
        case .waiting: "clock"
        case .sending, .cancelling, .held: "paperplane"
        case .failed: "exclamationmark.circle.fill"
        }
    }
}

/// A draft written here that Fastmail doesn't have yet. Delete asks first (`delete`), as for a message: what is
/// written here exists nowhere else.
struct OutboxDraftRow: View {
    let draft: Outbox.DraftSummary
    let actions: OutboxActions
    let delete: () -> Void

    static let deleteWarning =
        "What was written on this device can't be recovered. A copy in Fastmail's Drafts goes to Trash."

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                summary
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                summary
                buttons
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open") { actions.open(draft) }
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(OutboxRow.subject(draft.subject))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(draft.recipients.isEmpty ? "No recipients" : "To: " + RecipientField.summary(of: draft.recipients))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Saved on this device \(draft.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Open") { actions.open(draft) }
            Button("Delete", role: .destructive, action: delete)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
