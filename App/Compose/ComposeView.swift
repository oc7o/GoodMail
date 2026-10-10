import GoodMailCore
import JMAPKit
import MailCompose
import MailPrivacy
import SwiftUI
import UniformTypeIdentifiers

/// The composer: a window of its own on the Mac (§5.2), a sheet on iOS (§5.3).
///
/// Header, notices, attachments and the body are separate views reading separate parts of the composer, so a
/// keystroke in the body doesn't redraw the header. The editor and the formatting controls share one text and
/// one selection (C12). Closing keeps the draft (D11); Delete Draft is explicit.
struct ComposeView: View {
    @State private var flow: ComposeFlow
    @State private var selection = AttributedTextSelection()
    @State private var showsFormattingBar = true
    @FocusState private var isEditorFocused: Bool
    @Environment(MailAccount.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.compose) private var compose

    init(composer: Composer) {
        self.init(flow: ComposeFlow(composer: composer))
    }

    /// The render harness drives the flow it passes in, exactly as the buttons do.
    init(flow: ComposeFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        content
            .navigationTitle(flow.title)
            .navigationSubtitle(flow.saveStatusText)
            .toolbar { toolbar }
            .focusedSceneValue(\.composeFlow, flow)
            .attachmentPickers(flow.pickers, onFiles: { flow.attach(files: $0) },
                               onData: { flow.attach($0, name: $1, type: $2) })
            .sheet(isPresented: $flow.isReplacingToken) { ReplaceTokenView() }
            .alert(flow.alert?.title ?? "", isPresented: isShowingAlert, presenting: flow.alert) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .alert("Attach with Location?", isPresented: isAskingAboutLocation, presenting: flow.locationConsent) { consent in
                Button("Attach") { flow.answerLocationConsent(consent, attach: true) }
                Button("Cancel", role: .cancel) { flow.answerLocationConsent(consent, attach: false) }
            } message: { _ in
                Text(AttachmentError.locationNotRemovable("").localizedDescription)
            }
            .confirmationDialog(flow.identityConsentTitle, isPresented: isAskingForIdentity,
                                titleVisibility: .visible, presenting: flow.identityConsent) { address in
                Button("Create and Send") { flow.sendNow(consentingFor: address) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("GoodMail can create it; it then appears in Fastmail under Settings → My email addresses, "
                     + "where you can delete it.")
            }
            #if os(iOS)
            .confirmationDialog("Keep this message?", isPresented: $flow.isConfirmingClose, titleVisibility: .hidden) {
                Button("Delete Draft", role: .destructive) { flow.discardNow() }
                Button("Save Draft") { flow.saveAndFinish() }
                Button("Cancel", role: .cancel) {}
            }
            #else
            .confirmationDialog("Delete this draft?", isPresented: $flow.isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Draft", role: .destructive) { flow.discardNow() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its copy in Fastmail's Drafts goes to Trash.")
            }
            #endif
            .onChange(of: flow.isFinished) { _, finished in
                if finished { dismiss() }
            }
            .task {
                flow.account = account
                account.register(flow)
                // A reply is written right away; a new message or a forward starts with its recipients.
                let kind = flow.composer.kind
                if kind == .reply || kind == .replyAll, flow.composer.mode == .editing { isEditorFocused = true }
            }
            .onDisappear { flow.closeNow() }
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                messageBody
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        }
        .background(.background)
        .safeAreaBar(edge: .bottom) {
            if showsFormattingBar, isEditorFocused, flow.composer.mode == .editing {
                FormattingBar(text: Bindable(flow.composer).body, selection: $selection)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                messageBody
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A draft shown read-only (D32) changes nothing until Edit Anyway.
            ComposeHeader(flow: flow, account: account)
                .disabled(flow.composer.mode != .editing)
            ComposeStatusRows(flow: flow, account: account)
            AttachmentRow(flow: flow)
        }
    }

    @ViewBuilder private var messageBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch flow.composer.mode {
            case .preview:
                PreviewBanner { flow.composer.editAnyway() }
                ReadOnlyMessageBlock(
                    title: nil, html: flow.composer.previewHTML, text: flow.composer.previewText,
                    isCollapsible: false, inlineImage: { _ in nil })
                    .environment(\.openURL, mailtoAction)
            case .editing:
                ComposeBodyEditor(
                    text: Bindable(flow.composer).body, selection: $selection,
                    onFiles: { flow.attach(files: $0) },
                    onImage: { data, type in flow.attach(data, name: "Image", type: type) })
                    .focused($isEditorFocused)
                    .accessibilityLabel("Message")
                QuoteAndSignature(composer: flow.composer, account: account)
                    .environment(\.openURL, mailtoAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A `mailto:` link in the quote, the signature or a draft's preview opens GoodMail's composer, writing from
    /// the address the original came to (C8, D31), as in the reading pane.
    private var mailtoAction: OpenURLAction {
        .mailto(compose, sourceEmailID: flow.composer.draft.original?.emailID)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            ComposeSendButton(flow: flow)
        }
        ToolbarSpacer(.fixed, placement: .navigation)
        ToolbarItemGroup(placement: .navigation) {
            AttachMenu(pickers: flow.pickers)
                .disabled(flow.composer.mode != .editing)
            Toggle(isOn: $showsFormattingBar) {
                Label("Format", systemImage: "textformat")
            }
            .help(showsFormattingBar ? "Hide the formatting bar" : "Show the formatting bar")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Delete Draft", systemImage: "trash") { flow.requestDelete() }
                .help("Delete this draft")
        }
        #else
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { flow.requestClose() }
        }
        ToolbarItem(placement: .confirmationAction) {
            ComposeSendButton(flow: flow)
        }
        ToolbarItemGroup(placement: .keyboard) {
            if isEditorFocused, flow.composer.mode == .editing {
                FormattingControls(text: Bindable(flow.composer).body, selection: $selection)
            }
            Spacer()
            AttachMenu(pickers: flow.pickers)
        }
        #endif
    }

    // MARK: Presentations

    private var isShowingAlert: Binding<Bool> {
        Binding(get: { flow.alert != nil }, set: { if !$0 { flow.alert = nil } })
    }

    private var isAskingAboutLocation: Binding<Bool> {
        Binding(get: { flow.locationConsent != nil }, set: { _ in })
    }

    private var isAskingForIdentity: Binding<Bool> {
        Binding(get: { flow.identityConsent != nil }, set: { if !$0 { flow.identityConsent = nil } })
    }
}

extension FocusedValues {
    /// The composer in front, for Send (⇧⌘D) in the menu.
    @Entry var composeFlow: ComposeFlow?
}

// MARK: - Flow

/// What the composer's controls do, apart from the views: sending, closing, attaching, and what Send needs first.
/// The menu's Send and the render harness use it too.
@MainActor
@Observable
final class ComposeFlow {
    let composer: Composer
    @ObservationIgnored weak var account: MailAccount?
    /// What is typed in the recipient fields and not yet a token; Send and Close commit it first (P6).
    var toEntry = ""
    var ccEntry = ""
    var bccEntry = ""
    /// Cc and Bcc share one row until used.
    var showsCcAndBcc: Bool
    let pickers = AttachmentPickers()
    private(set) var isSending = false
    /// The composer is done (sent, deleted, or closed from the iOS dialog): its window or sheet goes.
    private(set) var isFinished = false
    var alert: ComposeAlert?
    /// Photos whose location can't be removed wait for the user's answer, one at a time.
    private(set) var locationConsents: [LocationConsent] = []
    var locationConsent: LocationConsent? { locationConsents.first }
    /// A masked address to create a sending identity for, if the user agrees (only while GoodMail may, D21).
    var identityConsent: String?
    var isConfirmingClose = false
    var isConfirmingDelete = false
    var isReplacingToken = false
    @ObservationIgnored private var isClosing = false
    /// The address the composer opened with: what "Use …" in the sender warning goes back to.
    let initialFrom: EmailAddress?

    init(composer: Composer) {
        self.composer = composer
        initialFrom = composer.from
        showsCcAndBcc = !composer.cc.isEmpty || !composer.bcc.isEmpty
    }

    var title: String {
        #if os(macOS)
        // A window's title goes into the Mac's saved window state, a file outside GoodMail's encrypted store, so
        // it doesn't carry the subject (§0.11): the title says what kind of message this is.
        switch composer.kind {
        case .new: "New Message"
        case .reply, .replyAll: "Reply"
        case .forward, .forwardAsAttachment: "Forward"
        }
        #else
        let subject = composer.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? "New Message" : subject
        #endif
    }

    var saveStatusText: String {
        switch composer.saveStatus {
        case .unsaved: ""
        case .savedLocally: Self.savedOnDevice
        case .savedToServer: "Saved to Drafts"
        case .failed: "Couldn't save to Fastmail"
        }
    }

    #if os(macOS)
    static let savedOnDevice = "Saved on this Mac"
    #else
    static let savedOnDevice = "Saved on this device"
    #endif

    // MARK: What stops Send

    /// The composer's problems, with an address still typed in a recipient field counting as a recipient:
    /// Send commits it first.
    var sendProblems: [SendProblem] {
        let isTyping = [toEntry, ccEntry, bccEntry].contains { !$0.allSatisfy(\.isWhitespace) }
        return composer.problems.filter { !(isTyping && $0 == .noRecipients) }
    }

    var canSend: Bool {
        composer.mode == .editing && !isSending && !isFinished && sendProblems.isEmpty
    }

    /// The first problem that the fields themselves don't show, explained in a row of its own.
    var explainedProblem: SendProblem? {
        sendProblems.first { problem in
            switch problem {
            case .noRecipients, .invalidAddresses, .noSender, .sentElsewhere: false
            default: true
            }
        }
    }

    /// What the disabled Send button's tooltip says.
    var sendHelp: String {
        if composer.mode != .editing { return "Edit the draft to send it" }
        return sendProblems.first?.localizedDescription ?? "Send (⇧⌘D)"
    }

    // MARK: Sending

    func sendNow(consentingFor address: String? = nil) {
        Task { await send(consentingFor: address) }
    }

    /// Commits what is typed, sends, and finishes the composer. A masked address without a sending identity
    /// asks for consent while GoodMail may create one (D21); otherwise the composer explains it and stays open,
    /// with the message a draft.
    func send(consentingFor address: String? = nil) async {
        guard !isSending, !isFinished else { return }
        commitEntries()
        isSending = true
        defer { isSending = false }
        let id = composer.id
        let subject = composer.subject
        let pendingUpload = bytesToUpload
        do {
            try await composer.send(consentingToSendingIdentityFor: address)
            isFinished = true
            account?.noteSent(id, subject: subject)
            #if os(iOS)
            if pendingUpload > BackgroundSending.continuedProcessingThreshold, let outbox = account?.mail.outbox {
                BackgroundSending.continueSending(id, subject: subject, outbox: outbox)
            }
            #endif
        } catch let problem as SendProblem {
            if case .needsSendingIdentity(let masked) = problem, MaskedSendPolicy.createsIdentities {
                identityConsent = masked
            } else {
                alert = ComposeAlert(title: "Can't Send Yet", message: problem.localizedDescription)
            }
        } catch {
            alert = ComposeAlert(title: "Couldn't Send", message: error.localizedDescription)
        }
    }

    var identityConsentTitle: String {
        "Fastmail needs a sending identity for \(identityConsent ?? "this address"). Create it and send?"
    }

    /// Local attachments the server doesn't have yet.
    private var bytesToUpload: Int {
        let uploads = composer.uploads
        return composer.attachments.filter { attachment in
            attachment.source == .local && uploads[attachment.id] != .uploaded
        }.reduce(0) { $0 + $1.size }
    }

    func commitEntries() {
        if !toEntry.allSatisfy(\.isWhitespace) { composer.to = RecipientField.committing(toEntry, to: composer.to) }
        if !ccEntry.allSatisfy(\.isWhitespace) { composer.cc = RecipientField.committing(ccEntry, to: composer.cc) }
        if !bccEntry.allSatisfy(\.isWhitespace) { composer.bcc = RecipientField.committing(bccEntry, to: composer.bcc) }
        toEntry = ""
        ccEntry = ""
        bccEntry = ""
    }

    // MARK: Closing

    /// The window or sheet went: the draft is kept (D11), with what was typed last.
    func closeNow() {
        guard !isClosing else { return }
        isClosing = true
        commitEntries()
        let composer = composer
        Task { await composer.close() }
    }

    /// iOS Close: asks Save Draft or Delete Draft when there is anything to keep.
    func requestClose() {
        if hasContent {
            isConfirmingClose = true
        } else {
            saveAndFinish()
        }
    }

    func saveAndFinish() {
        closeNow()
        isFinished = true
    }

    /// The Mac's Delete Draft asks first when there is anything to lose.
    func requestDelete() {
        if hasContent {
            isConfirmingDelete = true
        } else {
            discardNow()
        }
    }

    func discardNow() {
        Task {
            _ = await composer.discard()
            isFinished = true
        }
    }

    /// "Sent from another device": Close deletes this copy (§2.3).
    func closeSentElsewhere() {
        Task {
            await composer.close()
            isFinished = true
        }
    }

    var hasContent: Bool {
        !composer.to.isEmpty || !composer.cc.isEmpty || !composer.bcc.isEmpty || !composer.attachments.isEmpty
            || !composer.subject.allSatisfy(\.isWhitespace) || !composer.body.characters.allSatisfy(\.isWhitespace)
            || [toEntry, ccEntry, bccEntry].contains { !$0.allSatisfy(\.isWhitespace) }
    }

    // MARK: Sender

    /// The sender warning's way back to the address the composer opened with, when From was changed since.
    var addressToGoBackTo: EmailAddress? {
        guard let initialFrom, composer.senderWarning != nil,
              initialFrom.email.lowercased() != composer.from?.email.lowercased()
        else { return nil }
        return initialFrom
    }

    // MARK: Attachments

    func attach(files urls: [URL]) {
        Task {
            for url in urls {
                // A copy from Photos goes once attached, or once the user answered about its location.
                await attach(named: url.lastPathComponent, cleanup: { PickedFile.discard(url) }) { [composer] keepingLocation in
                    try await composer.addAttachment(fileAt: url, keepingLocation: keepingLocation)
                }
            }
        }
    }

    /// Data without a file name (a pasted image, a scan, a Continuity Camera photo) gets one from its type.
    func attach(_ data: Data, name: String, type: UTType) {
        let fileExtension = type.preferredFilenameExtension.map { "." + $0 } ?? ""
        let fileName = name.contains(".") || fileExtension.isEmpty ? name : name + fileExtension
        Task {
            await attach(named: fileName, cleanup: {}) { [composer] keepingLocation in
                try await composer.addAttachment(
                    data, name: fileName, typeIdentifier: type.identifier, keepingLocation: keepingLocation)
            }
        }
    }

    /// The answer to "Attach with Location?": attach the photo as it is, or leave it out.
    func answerLocationConsent(_ consent: LocationConsent, attach: Bool) {
        locationConsents.removeAll { $0.id == consent.id }
        Task {
            defer { consent.cleanup() }
            guard attach else { return }
            do {
                try await consent.add(true)
            } catch {
                alert = ComposeAlert(title: "Couldn't Attach \(consent.name)", message: error.localizedDescription)
            }
        }
    }

    private func attach(
        named name: String, cleanup: @escaping @MainActor () -> Void,
        _ add: @escaping @MainActor (Bool) async throws -> Void
    ) async {
        do {
            try await add(false)
            cleanup()
        } catch AttachmentError.locationNotRemovable {
            // A photo is attached with its location only when the user agrees (wave-2 addendum A).
            locationConsents.append(LocationConsent(name: name, add: add, cleanup: cleanup))
        } catch {
            cleanup()
            alert = ComposeAlert(title: "Couldn't Attach \(name)", message: error.localizedDescription)
        }
    }

    /// A failed upload tries again with the next save to Fastmail.
    func retryUploads() {
        let composer = composer
        Task { await composer.saveNow() }
    }

    /// Replaces this inline forward, which can't be sent, with a forward as an attachment (C20) and returns it
    /// for showing, with an address still typed in a recipient field. On the Mac this window goes; on iOS the
    /// new composer takes the sheet's place.
    func forwardAsAttachment() async -> Composer? {
        guard let account else { return nil }
        commitEntries()
        guard let replacement = await account.forwardAsAttachment(instead: composer) else {
            alert = ComposeAlert(
                title: "Couldn't Forward as Attachment",
                message: "The message stays as it is. Try again, or remove attachments that are missing.")
            return nil
        }
        #if os(macOS)
        isFinished = true
        #endif
        return replacement
    }
}

struct ComposeAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct LocationConsent: Identifiable {
    let id = UUID()
    let name: String
    let add: @MainActor (Bool) async throws -> Void
    /// Runs once the photo is attached or left out.
    let cleanup: @MainActor () -> Void
}

// MARK: - Header

/// To, Cc, Bcc, Subject and From. Cc and Bcc share one row until used (§5.2).
private struct ComposeHeader: View {
    @Bindable var flow: ComposeFlow
    let account: MailAccount

    var body: some View {
        @Bindable var composer = flow.composer
        VStack(alignment: .leading, spacing: 0) {
            field {
                recipientField("To:", recipients: $composer.to, entry: $flow.toEntry)
            }
            if flow.showsCcAndBcc {
                field { recipientField("Cc:", recipients: $composer.cc, entry: $flow.ccEntry) }
                field { recipientField("Bcc:", recipients: $composer.bcc, entry: $flow.bccEntry) }
            } else {
                field {
                    Button {
                        flow.showsCcAndBcc = true
                    } label: {
                        Text("Cc/Bcc:")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the Cc and Bcc fields")
                }
            }
            field {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Subject:")
                        .foregroundStyle(.secondary)
                    TextField("Subject", text: $composer.subject, prompt: Text(verbatim: ""))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                }
            }
            field {
                SenderPicker(from: $composer.from, options: account.mail.senderOptions())
            }
        }
    }

    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .padding(.horizontal, ComposeMetrics.inset)
                .padding(.vertical, 8)
            Divider()
                .padding(.leading, ComposeMetrics.inset)
        }
    }

    private func recipientField(
        _ label: LocalizedStringKey, recipients: Binding<[EmailAddress]>, entry: Binding<String>
    ) -> some View {
        let account = account
        let composer = flow.composer
        let masked = Set(account.mail.maskedEmails.map { $0.email.lowercased() })
        return RecipientField(
            label, recipients: recipients, entry: entry,
            suggestions: { query in
                let entered = Set((composer.to + composer.cc + composer.bcc).map { $0.email.lowercased() })
                return await account.recipients.suggestions(
                    for: query, excluding: entered, isOwn: { account.mail.isOwnAddress($0) })
            },
            contactsPrompt: contactsPrompt, isMasked: { masked.contains($0.lowercased()) })
    }

    /// The Contacts row of the suggestions while access isn't granted (D28); none once it is.
    private var contactsPrompt: ContactsPrompt? {
        let recipients = account.recipients
        let access: ContactsPromptAccess
        switch recipients.contactsAccess {
        case .authorized: return nil
        case .notDetermined: access = .notDetermined
        case .limited: access = .limited
        case .denied: access = .denied
        }
        return ContactsPrompt(access: access) { await recipients.requestContactsAccess() }
    }
}

enum ComposeMetrics {
    #if os(macOS)
    static let inset: CGFloat = 20
    #else
    static let inset: CGFloat = 16
    #endif
}

// MARK: - Status rows

/// What the composer has to say above the message: the sender warning, its notices, and why Send is off.
private struct ComposeStatusRows: View {
    let flow: ComposeFlow
    let account: MailAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let warning = flow.composer.senderWarning {
                StatusRow(systemImage: "exclamationmark.triangle.fill", tint: .yellow, text: warning) {
                    if let mask = inactiveMask {
                        // D22: replying from a disabled or deleted mask is allowed; switching it back on is a tap.
                        Button("Enable Address") {
                            Task { await account.mail.setMaskedEmailState(.enabled, id: mask.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let address = flow.addressToGoBackTo {
                        Button("Use \(address.email)") { flow.composer.from = address }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            ForEach(Array(flow.composer.notices.enumerated()), id: \.offset) { _, notice in
                noticeRow(notice)
            }
            SendProblemRow(flow: flow)
        }
    }

    /// The masked address From is, when it is disabled or deleted.
    private var inactiveMask: MaskedEmail? {
        guard let from = flow.composer.from?.email.lowercased() else { return nil }
        let mask = account.mail.maskedEmails.first { $0.email.lowercased() == from }
        return mask?.state == .disabled || mask?.state == .deleted ? mask : nil
    }

    @ViewBuilder private func noticeRow(_ notice: ComposerNotice) -> some View {
        switch notice {
        case .sentElsewhere:
            StatusRow(systemImage: "paperplane.circle.fill", tint: .orange,
                      text: "Sent from another device. Close it, or keep it as a new message to send it again.") {
                Button("Close") { flow.closeSentElsewhere() }
                    .controlSize(.small)
                Button("Keep as New Message") { Task { await flow.composer.keepAsNewMessage() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        default:
            StatusRow(systemImage: "info.circle.fill", tint: .blue, text: Self.text(of: notice)) {
                Button("Dismiss", systemImage: "xmark") { flow.composer.dismiss(notice) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func text(of notice: ComposerNotice) -> String {
        switch notice {
        case .otherVersionKept: "Also changed on another device – both versions are kept."
        case .sentElsewhere: "Sent from another device."
        case .deletedElsewhereRestored: "Deleted on another device – kept here with your changes."
        case .quoteShortened: "Quote shortened: the original is too long to quote in full."
        case .originalUnavailableOffline: "The original isn't on this device, so it isn't quoted."
        case .attachmentsNotOnServerYet: "Attachments not on Fastmail yet: the draft there doesn't have them."
        }
    }
}

/// Why Send is off, when the fields don't show it themselves, with the way out where there is one.
private struct SendProblemRow: View {
    let flow: ComposeFlow
    @Environment(\.compose) private var compose

    var body: some View {
        if let problem = flow.explainedProblem {
            StatusRow(systemImage: "exclamationmark.circle.fill", tint: .red, text: problem.localizedDescription) {
                switch problem {
                case .cannotSend(.tokenLacksSubmission), .cannotSend(.unknown):
                    Button("Replace Token…") { flow.isReplacingToken = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .inlineForwardIncomplete:
                    Button("Forward as Attachment") {
                        Task {
                            if let replacement = await flow.forwardAsAttachment() { compose(.restore(replacement.id)) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
    }
}

/// A content row (no glass) under the header: a tinted symbol, the text, and actions.
private struct StatusRow<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
            .font(.callout)
            .padding(.horizontal, ComposeMetrics.inset)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12))
            Divider()
        }
    }
}

/// D32: a draft from another client that GoodMail can't edit without loss.
private struct PreviewBanner: View {
    let editAnyway: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
            Text("This draft uses formatting GoodMail can't edit (images, tables). Editing simplifies it; the "
                 + "original is kept in Trash.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit Anyway", action: editAnyway)
                .buttonStyle(.bordered)
        }
        .font(.callout)
        .padding(12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
    }
}

// MARK: - Attachments

/// The attachment chips under the header, scrolling sideways, and how much of Fastmail's limit they use once
/// that passes 70 %.
private struct AttachmentRow: View {
    let flow: ComposeFlow

    var body: some View {
        let composer = flow.composer
        if !composer.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(composer.attachments) { attachment in
                            chip(attachment)
                        }
                    }
                    .padding(.horizontal, ComposeMetrics.inset)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                if let usage = Self.usage(count: composer.attachments.count, bytes: composer.attachmentBytes,
                                          limit: composer.attachmentLimit) {
                    Text(usage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, ComposeMetrics.inset)
                        .padding(.bottom, 6)
                }
                Divider()
            }
        }
    }

    private func chip(_ attachment: DraftAttachment) -> some View {
        let state = state(of: attachment)
        let composer = flow.composer
        let remove: (() -> Void)? = composer.mode == .editing
            ? { Task { await composer.removeAttachment(attachment.id) } } : nil
        return AttachmentChip(
            name: attachment.name, size: attachment.size,
            typeIdentifier: UTType(mimeType: attachment.type)?.identifier, state: state, onRemove: remove
        )
        .modifier(ChipAction(action: action(for: state, of: attachment), remove: remove))
    }

    /// What tapping a chip does: retry a failed upload, or attach a file again whose data is gone.
    private func action(for state: AttachmentChip.State, of attachment: DraftAttachment) -> ChipAction.Action? {
        let composer = flow.composer
        let flow = flow
        switch state {
        case .failed:
            return ChipAction.Action(title: "Retry Upload") { flow.retryUploads() }
        case .missing:
            return ChipAction.Action(title: "Attach Again…") {
                Task { await composer.removeAttachment(attachment.id) }
                flow.pickers.isImportingFiles = true
            }
        default:
            return nil
        }
    }

    private func state(of attachment: DraftAttachment) -> AttachmentChip.State {
        let lost = flow.composer.problems.contains { problem in
            if case .attachmentDataLost(let names) = problem { return names.contains(attachment.name) }
            return false
        }
        if lost, attachment.source == .local { return .missing }
        switch flow.composer.uploads[attachment.id] {
        case .uploading(let progress)?: return .uploading(progress)
        case .failed?: return .failed("Upload failed – tap to retry")
        case .waiting?, .uploaded?, nil: return .ready
        }
    }

    /// "3 attachments · 37 MB of 50 MB", once they use more than 70 % of the limit.
    static func usage(count: Int, bytes: Int, limit: Int?) -> String? {
        guard let limit, limit > 0, bytes * 10 > limit * 7 else { return nil }
        let size = { (value: Int) in ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
        return "\(count) attachment\(count == 1 ? "" : "s") · \(size(bytes)) of \(size(limit))"
    }
}

/// A chip that does something when tapped, as a control: a button to VoiceOver with the action named, a context
/// menu with it and Remove, and a stop for the keyboard's focus that Space or Return acts on.
private struct ChipAction: ViewModifier {
    struct Action {
        let title: String
        let run: () -> Void
    }

    let action: Action?
    let remove: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .onTapGesture(perform: action.run)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(action.title), action.run)
                .contextMenu {
                    Button(action.title, action: action.run)
                    if let remove { Button("Remove", role: .destructive, action: remove) }
                }
                .focusable()
                .onKeyPress(keys: [.space, .return]) { _ in
                    action.run()
                    return .handled
                }
        } else {
            content
        }
    }
}

// MARK: - Signature and quote

/// Under the editor, read-only: the signature, dimmed, and the quoted original or a draft's preserved tail,
/// collapsible (D1).
private struct QuoteAndSignature: View {
    let composer: Composer
    let account: MailAccount

    var body: some View {
        if let signature = composer.signature, !signature.isEmpty {
            ReadOnlyMessageBlock(title: nil, html: signature.html, text: signature.text, isCollapsible: false) { _ in nil }
                .opacity(0.7)
                .accessibilityLabel("Signature")
        }
        if let tail = composer.preservedTail {
            ReadOnlyMessageBlock(title: nil, html: tail.html, text: tail.text, isCollapsible: true) { cid in
                await account.inlineImage(cid: cid, among: tail.inlineParts)
            }
        } else if let quote = composer.quote {
            let parts = composer.draft.original?.inlineParts ?? []
            let isForward = composer.kind == .forward
            ReadOnlyMessageBlock(
                title: isForward ? "Begin forwarded message:" : MessageAssembler.attribution(for: quote),
                html: quote.html, text: quote.text, isCollapsible: !isForward
            ) { cid in
                await account.inlineImage(cid: cid, among: parts)
            }
        }
    }
}

// MARK: - Send

/// Send: glass, prominent, off with the first problem as its tooltip while the message can't go (§5.2, §5.3).
struct ComposeSendButton: View {
    let flow: ComposeFlow

    var body: some View {
        Button {
            flow.sendNow()
        } label: {
            if flow.isSending {
                ProgressView().controlSize(.small)
            } else {
                Label("Send", systemImage: Self.symbol)
            }
        }
        .buttonStyle(.glassProminent)
        .disabled(!flow.canSend)
        .help(flow.sendHelp)
        .accessibilityHint(flow.canSend ? "" : flow.sendHelp)
    }

    #if os(macOS)
    static let symbol = "paperplane.fill"
    #else
    static let symbol = "arrow.up"
    #endif
}
