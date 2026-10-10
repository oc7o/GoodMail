import JMAPKit
import MailCompose
import SwiftUI
#if os(iOS)
import ContactsUI
#endif

/// Whether recipient suggestions may use Contacts yet. An app-local mirror of GoodMailCore's
/// `RecipientDirectory.Access`; with full access no prompt is needed, and the app passes no `ContactsPrompt`.
enum ContactsPromptAccess {
    case notDetermined, limited, denied
}

/// The row at the end of the suggestions that asks for Contacts access (D28), or, with limited access on iOS,
/// lets the user share more contacts.
struct ContactsPrompt {
    var access: ContactsPromptAccess
    var request: () async -> Void
}

/// A To, Cc or Bcc field: flowing address tokens followed by the text being typed.
///
/// - Comma, semicolon or Return turn the text into tokens (a comma in a quoted name doesn't); a paste such as
///   "A <a@x>, b@y" is split by `AddressParser`, and an incomplete last item stays as text.
/// - Backspace in the empty field selects the last token, a second Backspace removes it.
/// - Tokens are content, not glass: invalid addresses are red, masked addresses carry a `theatermasks` glyph, and
///   each has Copy Address, Edit and Remove (plus Add to Contacts when the app offers it) in its context menu.
/// - Without focus, two or more recipients collapse to "Maya & 2 more".
/// - Suggestions come from `suggestions` as the user types: in the system completion list on the Mac, in a list
///   under the field on iOS. While Contacts access is undecided, the last row offers it; with limited access on
///   iOS it is the system's `ContactAccessButton`.
///
/// Typed text becomes tokens only on a separator, on Return or when the field loses focus, and SwiftUI reports the
/// lost focus only after the action that took it; a Send button or ⇧⌘D takes none at all. A composer therefore
/// passes `entry` and, before it sends or closes, commits what is still typed with `committing(_:to:)`, or the
/// address typed last is left out.
struct RecipientField: View {
    private let label: LocalizedStringKey
    @Binding private var recipients: [EmailAddress]
    private let sharedEntry: Binding<String>?
    private let suggestions: (String) async -> [AddressSuggestion]
    private let contactsPrompt: ContactsPrompt?
    private let isMasked: (String) -> Bool
    private let addToContacts: ((EmailAddress) -> Void)?

    @State private var ownEntry = ""
    @State private var suggested: [AddressSuggestion] = []
    @State private var selectedToken: Int?
    @State private var wantsFocus = false
    @State private var isRequestingContacts = false
    @FocusState private var isFocused: Bool

    /// - Parameter entry: the text typed and not yet a token; the field keeps it to itself when it's nil.
    init(
        _ label: LocalizedStringKey, recipients: Binding<[EmailAddress]>, entry: Binding<String>? = nil,
        suggestions: @escaping (String) async -> [AddressSuggestion], contactsPrompt: ContactsPrompt?,
        isMasked: @escaping (String) -> Bool, addToContacts: ((EmailAddress) -> Void)? = nil
    ) {
        self.label = label
        _recipients = recipients
        sharedEntry = entry
        self.suggestions = suggestions
        self.contactsPrompt = contactsPrompt
        self.isMasked = isMasked
        self.addToContacts = addToContacts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                if showsSummary {
                    summary
                } else {
                    RecipientFlowLayout {
                        ForEach(Array(recipients.enumerated()), id: \.offset) { index, address in
                            token(address, at: index)
                        }
                        field
                    }
                }
            }
            if isFocused {
                #if os(iOS)
                suggestionList
                #endif
                contactsRow
            }
        }
        .task(id: isFocused ? entry : nil) { await loadSuggestions() }
    }

    // MARK: Tokens

    private func token(_ address: EmailAddress, at index: Int) -> some View {
        RecipientToken(
            address: address, isValid: AddressParser.isValid(address.email), isMasked: isMasked(address.email),
            isSelected: selectedToken == index
        )
        .onTapGesture {
            selectedToken = index
            isFocused = true
        }
        .contextMenu {
            Button("Copy Address", systemImage: "doc.on.doc") { Pasteboard.copy(address.email) }
            Button("Edit", systemImage: "pencil") { edit(at: index) }
            Button("Remove", systemImage: "minus.circle") { remove(at: index) }
            if let addToContacts {
                Divider()
                Button("Add to Contacts", systemImage: "person.crop.circle.badge.plus") { addToContacts(address) }
            }
        }
        .accessibilityAction(named: "Remove") { remove(at: index) }
        .accessibilityAction(named: "Edit") { edit(at: index) }
    }

    private var summary: some View {
        Button {
            wantsFocus = true
        } label: {
            HStack(spacing: 4) {
                Text(Self.summary(of: recipients))
                    .lineLimit(1)
                if recipients.contains(where: { !AddressParser.isValid($0.email) }) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Contains an invalid address")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows all recipients")
    }

    /// "Maya Lindqvist & 2 more".
    static func summary(of recipients: [EmailAddress]) -> String {
        guard let first = recipients.first else { return "" }
        let name = first.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? first.email
        return recipients.count == 1 ? name : "\(name) & \(recipients.count - 1) more"
    }

    private var showsSummary: Bool {
        !isFocused && !wantsFocus && recipients.count > 1 && entry.isEmpty
    }

    // MARK: Typing

    private var entryBinding: Binding<String> {
        sharedEntry ?? $ownEntry
    }

    private var entry: String {
        get { entryBinding.wrappedValue }
        nonmutating set { entryBinding.wrappedValue = newValue }
    }

    private var field: some View {
        TextField(text: entryBinding, prompt: Text(verbatim: "")) {
            Text(label)
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .focused($isFocused)
        .autocorrectionDisabled()
        #if os(iOS)
        .textContentType(.emailAddress)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        #else
        .textInputSuggestions(suggested) { suggestion in
            RecipientSuggestionRow(suggestion: suggestion)
                .textInputCompletion(Self.completion(for: suggestion))
        }
        #endif
        .onSubmit(commitEntry)
        #if os(macOS)
        .background {
            RecipientBackspaceMonitor(isActive: isFocused, onBackspace: backspaceInEmptyField)
        }
        #else
        .onKeyPress(.delete) { backspaceInEmptyField() ? .handled : .ignored }
        #endif
        .onChange(of: entry) { _, value in entryChanged(value) }
        .onChange(of: isFocused) { _, focused in
            if focused {
                wantsFocus = false
            } else {
                commitEntry()
                selectedToken = nil
            }
        }
        .task(id: wantsFocus) {
            if wantsFocus { isFocused = true }
        }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "," || character == ";" || character.isNewline
    }

    /// Whether `text` holds a comma, semicolon or line break outside quotes and angle brackets, read the way
    /// `AddressParser` reads it: the comma in `"Berg, Alex" <alex@berg.example>` ends nothing.
    static func endsAnAddress(_ text: String) -> Bool {
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" && !inBrackets {
                inQuotes.toggle()
            } else if !inQuotes && character == "<" {
                inBrackets = true
            } else if !inQuotes && character == ">" {
                inBrackets = false
            } else if !inQuotes && !inBrackets && isSeparator(character) {
                return true
            }
        }
        return false
    }

    private func entryChanged(_ value: String) {
        selectedToken = nil
        guard Self.endsAnAddress(value) else { return }
        let (addresses, remainder) = AddressParser.parse(value)
        add(addresses)
        if entry != remainder { entry = remainder }
    }

    /// Return, or leaving the field: whatever was typed becomes a token, red if it isn't a valid address.
    private func commitEntry() {
        guard !entry.allSatisfy(\.isWhitespace) else { return }
        recipients = Self.committing(entry, to: recipients)
        entry = ""
    }

    /// `recipients` with `entry` committed as Return commits it: every item becomes an address, red when it isn't
    /// valid, so a send stops at it instead of leaving it out; addresses already there aren't added again.
    static func committing(_ entry: String, to recipients: [EmailAddress]) -> [EmailAddress] {
        guard !entry.allSatisfy(\.isWhitespace) else { return recipients }
        // The comma ends the last item, unless a quote or bracket is still open; then that item stays whole.
        var (addresses, unfinished) = AddressParser.parse(entry + ",")
        if !unfinished.isEmpty {
            addresses.append(EmailAddress(name: nil, email: String(unfinished.dropLast())))
        }
        return adding(addresses, to: recipients)
    }

    /// Whether Backspace was used here: the first selects the last token, the next removes the selected one.
    private func backspaceInEmptyField() -> Bool {
        guard entry.isEmpty, !recipients.isEmpty else { return false }
        if let selected = selectedToken, recipients.indices.contains(selected) {
            remove(at: selected)
        } else {
            selectedToken = recipients.count - 1
        }
        return true
    }

    private func add(_ addresses: [EmailAddress]) {
        recipients = Self.adding(addresses, to: recipients)
    }

    private static func adding(_ addresses: [EmailAddress], to recipients: [EmailAddress]) -> [EmailAddress] {
        var result = recipients
        var known = Set(recipients.map { $0.email.lowercased() })
        for address in addresses where known.insert(address.email.lowercased()).inserted {
            result.append(address)
        }
        return result
    }

    private func remove(at index: Int) {
        guard recipients.indices.contains(index) else { return }
        recipients.remove(at: index)
        selectedToken = nil
    }

    private func edit(at index: Int) {
        guard recipients.indices.contains(index) else { return }
        let address = recipients.remove(at: index)
        selectedToken = nil
        commitEntry()
        entry = Self.editableText(address)
        wantsFocus = true
    }

    /// The address as it would be typed: `"Berg, Alex" <alex@berg.example>`, or just the address.
    static func editableText(_ address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return address.email }
        let needsQuotes = name.contains { ",;<>\"@()[]:\\".contains($0) }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let quoted = needsQuotes ? "\"" + escaped + "\"" : name
        return "\(quoted) <\(address.email)>"
    }

    /// A completion ends in a separator, so choosing it in the Mac's suggestion list turns it into a token.
    static func completion(for suggestion: AddressSuggestion) -> String {
        editableText(suggestion.address) + ", "
    }

    // MARK: Suggestions

    private func loadSuggestions() async {
        let query = entry.trimmingCharacters(in: .whitespaces)
        guard isFocused, !query.isEmpty else {
            suggested = []
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let entered = Set(recipients.map { $0.email.lowercased() })
        let found = await suggestions(query).filter { !entered.contains($0.id) }
        guard !Task.isCancelled else { return }
        suggested = found
    }

    #if os(iOS)
    @ViewBuilder private var suggestionList: some View {
        if !suggested.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggested) { suggestion in
                    Button {
                        add([suggestion.address])
                        entry = ""
                    } label: {
                        RecipientSuggestionRow(suggestion: suggestion)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
    #endif

    @ViewBuilder private var contactsRow: some View {
        if let contactsPrompt {
            switch contactsPrompt.access {
            case .notDetermined:
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text("Suggest people from Contacts")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Allow") {
                        isRequestingContacts = true
                        Task {
                            await contactsPrompt.request()
                            isRequestingContacts = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRequestingContacts)
                }
                .font(.subheadline)
            case .limited:
                #if os(iOS)
                if !entry.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContactAccessButton(
                        queryString: entry.trimmingCharacters(in: .whitespaces),
                        ignoredEmails: Set(recipients.map(\.email) + suggested.map(\.address.email))
                    ) { _ in
                        Task { await loadSuggestions() }
                    }
                    .contactAccessButtonCaption(.email)
                }
                #else
                EmptyView()
                #endif
            case .denied:
                EmptyView()
            }
        }
    }
}

#if os(macOS)
/// Backspace in an empty text field changes no text, so the field reports nothing, and `onKeyPress` doesn't see the
/// keys a text field handles itself. While the field has focus, a local event monitor watches for Backspace in the
/// field's window and hands it to the field first.
private struct RecipientBackspaceMonitor: NSViewRepresentable {
    let isActive: Bool
    let onBackspace: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onBackspace = onBackspace
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.isActive = false
    }

    final class MonitorView: NSView {
        var onBackspace: () -> Bool = { false }
        var isActive = false {
            didSet { isActive ? start() : stop() }
        }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { isActive = false }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            let backspaceKeyCode: UInt16 = 51
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let window, event.window === window, event.keyCode == backspaceKeyCode, modifiers.isEmpty,
                  (window.firstResponder as? NSTextView)?.isFieldEditor == true
            else { return false }
            return onBackspace()
        }
    }
}
#endif

/// One recipient as a token: content, not glass.
private struct RecipientToken: View {
    let address: EmailAddress
    let isValid: Bool
    let isMasked: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isMasked {
                Image(systemName: "theatermasks")
                    .imageScale(.small)
                    .accessibilityLabel("Masked address")
            }
            Text(address.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? address.email)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(foreground)
        .background(background, in: .capsule)
        .help(address.email)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        return isValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.red)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(isValid ? Color.accentColor : .red) }
        return isValid ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.red.opacity(0.15))
    }

    private var accessibilityText: String {
        var parts = [address.name ?? "", address.email].filter { !$0.isEmpty }
        if isMasked { parts.append("masked address") }
        if !isValid { parts.append("invalid address") }
        return parts.joined(separator: ", ")
    }
}

/// A suggested recipient: the name with the address under it, and where the suggestion comes from.
struct RecipientSuggestionRow: View {
    let suggestion: AddressSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: suggestion.source == .correspondent ? "clock" : "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                if let name = suggestion.address.name, !name.isEmpty {
                    Text(name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(suggestion.address.email)
                    if let detail = suggestion.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    private var subtitle: String {
        [suggestion.address.email, suggestion.detail].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Tokens flow onto as many lines as they need; the text field takes the rest of the last line, or a line of its
/// own when too little is left.
private struct RecipientFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    var minimumFieldWidth: CGFloat = 90

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let width = proposal.width ?? lines.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            for item in line.items {
                let origin = CGPoint(x: bounds.minX + item.x, y: y + (line.height - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width proposedWidth: CGFloat?, subviews: Subviews) -> [Line] {
        let maxWidth = proposedWidth ?? .infinity
        var lines = [Line()]
        for index in subviews.indices {
            let isField = index == subviews.count - 1
            var x = lines[lines.count - 1].width
            if x > 0 { x += spacing }
            var size: CGSize
            if isField {
                var available = maxWidth.isFinite ? maxWidth - x : minimumFieldWidth
                if available < minimumFieldWidth, x > 0 {
                    lines.append(Line())
                    x = 0
                    available = maxWidth.isFinite ? maxWidth : minimumFieldWidth
                }
                size = subviews[index].sizeThatFits(ProposedViewSize(width: available, height: nil))
                size.width = available
            } else {
                size = subviews[index].sizeThatFits(.unspecified)
                size.width = min(size.width, maxWidth)
                if x > 0, x + size.width > maxWidth {
                    lines.append(Line())
                    x = 0
                }
            }
            lines[lines.count - 1].items.append((index, x, size))
            lines[lines.count - 1].width = x + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }
}
