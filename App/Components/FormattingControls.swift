import MailCompose
import SwiftUI

/// The composer's formatting controls: bold, italic, underline, strikethrough; a Text Style menu with the four
/// sizes, the colour palette and monospace; lists; and links. On iOS they are the keyboard toolbar's content;
/// on the Mac `FormattingBar` puts them in a glass capsule.
///
/// They edit the same text and selection as `ComposeBodyEditor` (C12), so a control acts on what is selected
/// there, or on the typing style at the insertion point, and shows the state of the selection, as in Mail.
struct FormattingControls: View {
    @Binding private var text: AttributedString
    @Binding private var selection: AttributedTextSelection

    @Environment(\.fontResolutionContext) private var fontContext
    @State private var isEditingLink = false

    init(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>) {
        _text = text
        _selection = selection
    }

    var body: some View {
        let state = text.formattingState(for: selection, in: fontContext)
        Group {
            fontToggle("Bold", systemImage: "bold", isOn: state.isBold) { $0.isBold = $1 }
                .help("Bold")
            fontToggle("Italic", systemImage: "italic", isOn: state.isItalic) { $0.isItalic = $1 }
                .help("Italic")
            toggle("Underline", systemImage: "underline", isOn: state.isUnderlined) { on in
                edit { $0.setUnderline(on, selection: &$1) }
            }
            .help("Underline")
            toggle("Strikethrough", systemImage: "strikethrough", isOn: state.isStruckThrough) { on in
                edit { $0.setStrikethrough(on, selection: &$1) }
            }
            .help("Strikethrough")
            textStyleMenu(state)
            listMenu(state)
            Button("Link", systemImage: "link") { isEditingLink = true }
                .help(state.link == nil ? "Add a link" : "Edit the link")
                .popover(isPresented: $isEditingLink) {
                    LinkEditor(url: state.link) { url in
                        edit { $0.setLink(url, selection: &$1) }
                    }
                }
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
    }

    // MARK: Controls

    private func toggle(
        _ title: String, systemImage: String, isOn: Bool, set: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        Toggle(title, systemImage: systemImage, isOn: Binding(get: { isOn }, set: set))
    }

    private func fontToggle(
        _ title: String, systemImage: String, isOn: Bool,
        change: @escaping @Sendable (inout MailFontStyle, Bool) -> Void
    ) -> some View {
        toggle(title, systemImage: systemImage, isOn: isOn) { on in
            updateFont { change(&$0, on) }
        }
    }

    private func textStyleMenu(_ state: FormattingState) -> some View {
        Menu {
            Picker("Size", selection: Binding(get: { state.size }, set: { size in updateFont { $0.size = size } })) {
                ForEach(MailFontStyle.Size.allCases, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.inline)
            Picker("Color", selection: Binding(
                get: { state.color?.name ?? Self.automaticColor },
                set: { name in edit { $0.setColor(MailPalette.colors.first { $0.name == name }, selection: &$1) } }
            )) {
                Label("Automatic", systemImage: "circle.lefthalf.filled")
                    .tint(.primary)
                    .tag(Self.automaticColor)
                ForEach(MailPalette.colors, id: \.name) { entry in
                    Label(entry.name, systemImage: "circle.fill")
                        .tint(entry.color)
                        .tag(entry.name)
                }
            }
            .pickerStyle(.palette)
            Toggle("Monospaced", systemImage: "chevron.left.forwardslash.chevron.right", isOn: Binding(
                get: { state.isMonospaced }, set: { on in updateFont { $0.isMonospaced = on } }
            ))
            .toggleStyle(.automatic)
        } label: {
            Label("Text Style", systemImage: "textformat.size")
        }
        .menuIndicator(.hidden)
        .help("Size, colour and monospace")
    }

    private func listMenu(_ state: FormattingState) -> some View {
        Menu {
            Toggle("Bulleted List", systemImage: "list.bullet", isOn: Binding(
                get: { state.isList && !state.isNumberedList },
                set: { _ in edit { $0.toggleList(numbered: false, selection: &$1) } }
            ))
            Toggle("Numbered List", systemImage: "list.number", isOn: Binding(
                get: { state.isNumberedList },
                set: { _ in edit { $0.toggleList(numbered: true, selection: &$1) } }
            ))
        } label: {
            Label("List", systemImage: state.isNumberedList ? "list.number" : "list.bullet")
        }
        .toggleStyle(.automatic)
        .menuIndicator(.hidden)
        .help("Bulleted or numbered list")
    }

    // MARK: Editing

    private static let automaticColor = ""

    private func updateFont(_ change: @escaping (inout MailFontStyle) -> Void) {
        let context = fontContext
        edit { $0.updateFont(change, selection: &$1, in: context) }
    }

    /// Edits a copy and writes text before selection, the order the editor itself uses.
    private func edit(_ change: (inout AttributedString, inout AttributedTextSelection) -> Void) {
        var newText = text
        var newSelection = selection
        change(&newText, &newSelection)
        text = newText
        selection = newSelection
    }
}

/// The Mac composer's formatting bar: the formatting controls as glass buttons in one `GlassEffectContainer`, so
/// they read as a single floating capsule. The composer shows it at the bottom (`.safeAreaBar`) while the editor
/// has focus.
struct FormattingBar: View {
    @Binding private var text: AttributedString
    @Binding private var selection: AttributedTextSelection

    init(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>) {
        _text = text
        _selection = selection
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 4) {
                FormattingControls(text: $text, selection: $selection)
            }
            .buttonStyle(.glass)
            .menuStyle(.button)
            .controlSize(.large)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Edits the link of the selection. Links are kept exactly as entered (they aren't cleaned of tracking
/// parameters; the user chose them); an address becomes a `mailto:` link and a phone number a `tel:` link, and
/// only web, mail and phone links are accepted, the ones a recipient can safely follow.
struct LinkEditor: View {
    private let url: URL?
    private let onDone: (URL?) -> Void

    @State private var entry: String
    @Environment(\.dismiss) private var dismiss

    init(url: URL?, onDone: @escaping (URL?) -> Void) {
        self.url = url
        self.onDone = onDone
        _entry = State(initialValue: url.map(Self.displayString) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url == nil ? "Add Link" : "Edit Link")
                .font(.headline)
            TextField("Link", text: $entry, prompt: Text("https://… or name@example.com"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(apply)
            if !entry.isEmpty, parsed == nil {
                Text("Enter a web address, an email address or a phone number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if url != nil {
                    Button("Remove Link", role: .destructive) {
                        onDone(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(url == nil ? "Add" : "Change", action: apply)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding()
        .frame(minWidth: 320)
        #if os(iOS)
        .presentationDetents([.height(220)])
        #endif
    }

    private var parsed: URL? {
        Self.url(from: entry)
    }

    private func apply() {
        guard let parsed else { return }
        onDone(parsed)
        dismiss()
    }

    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// What the user typed as a link: kept as entered when it has an allowed scheme; otherwise an address gets
    /// `mailto:`, a phone number `tel:` and anything else `https://`.
    static func url(from entry: String) -> URL? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) || isPhoneNumber(trimmed) else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), trimmed.contains(":") {
            guard allowedSchemes.contains(scheme) else { return nil }
            if scheme == "http" || scheme == "https" { return url.host() == nil ? nil : url }
            return url
        }
        if AddressParser.isValid(trimmed) {
            return URL(string: "mailto:" + trimmed)
        }
        if isPhoneNumber(trimmed) {
            return URL(string: "tel:" + trimmed.filter { $0.isNumber || $0 == "+" })
        }
        guard let url = URL(string: "https://" + trimmed), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    private static func isPhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return digits.count >= 3 && text.allSatisfy { $0.isNumber || " +-()/".contains($0) }
    }

    private static func displayString(_ url: URL) -> String {
        let string = url.absoluteString
        for scheme in ["mailto:", "tel:"] where string.lowercased().hasPrefix(scheme) {
            return String(string.dropFirst(scheme.count))
        }
        return string
    }
}
