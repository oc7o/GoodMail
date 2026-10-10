import MailCompose
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import ObjectiveC
#endif

/// The text of a message being written: SwiftUI's rich `TextEditor`, held to what mail can carry.
///
/// - `MailBodyFormatting` constrains what is typed and pasted, and Writing Tools may answer with rich text (D7).
/// - Return in a list item starts the next item, Return in an empty item ends the list. The editor writes the
///   selection after the text, so this runs once both have arrived.
/// - Files pasted or dropped become attachments through `onFiles`, never their paths as text (C27). On the Mac a
///   pasted image without a file (a screenshot) goes to `onImage`, when given, so it can be attached too (D3).
/// - The system's own formatting bars are hidden in favour of `FormattingBar` and `FormattingControls`; the
///   context menu's formatting stays.
/// - The editor grows with its text, so the composer's one scroll view does all the scrolling (R-editor E9).
struct ComposeBodyEditor: View {
    @Binding private var text: AttributedString
    @Binding private var selection: AttributedTextSelection
    private let onFiles: ([URL]) -> Void
    private let onImage: ((Data, UTType) -> Void)?

    init(
        text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>,
        onFiles: @escaping ([URL]) -> Void, onImage: ((Data, UTType) -> Void)? = nil
    ) {
        _text = text
        _selection = selection
        self.onFiles = onFiles
        self.onImage = onImage
    }

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.body)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .attributedTextFormattingDefinition(MailBodyFormatting())
            .writingToolsBehavior(.complete)
            .textInputFormattingControlVisibility(.hidden, for: Self.replacedSystemControls)
            .onChange(of: text) { old, new in
                textChanged(from: old, to: new)
            }
            #if os(macOS)
            .background {
                EditorPasteboardInterceptor(onFiles: onFiles, onImage: onImage)
            }
            #else
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                receiveDroppedFiles(providers)
            }
            #endif
    }

    #if os(macOS)
    static let replacedSystemControls: TextInputFormattingControlPlacement.Set = [.accessoryBar, .fontPanel]
    #else
    static let replacedSystemControls: TextInputFormattingControlPlacement.Set = .inputAssistant
    #endif

    private func textChanged(from old: AttributedString, to new: AttributedString) {
        if new.characters.contains(Self.objectReplacement) {
            removeAttachmentCharacters()
        } else if new.characters.count == old.characters.count + 1 {
            Task { @MainActor in continueList() }
        }
    }

    /// One character more may be the line break that ends a list item: continue the list, or end it on an
    /// empty item. Runs on the next main-actor turn, after the editor has written the selection too.
    private func continueList() {
        var newText = text
        var newSelection = selection
        guard newText.continueList(selection: &newSelection) else { return }
        text = newText
        selection = newSelection
    }

    /// The editor has no attachments (D3); an image that slips in as an attachment character would reach the
    /// recipient as a stray "￼", so the character goes.
    private func removeAttachmentCharacters() {
        var newText = text
        var newSelection = selection
        newText.transform(updating: &newSelection) { text in
            while let index = text.characters.firstIndex(of: Self.objectReplacement) {
                text.removeSubrange(index..<text.characters.index(after: index))
            }
        }
        text = newText
        selection = newSelection
    }

    private static let objectReplacement: Character = "\u{FFFC}"

    #if os(iOS)
    /// Drops the text view declines (files from Files or another app) arrive here as file URLs.
    private func receiveDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let onFiles = onFiles
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            if !urls.isEmpty { onFiles(urls) }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }
    #endif
}

#if os(macOS)

// MARK: - Files and images pasted or dropped into the editor (macOS)

/// Finds the editor's text view once it is on screen and hands it the paste handlers.
///
/// It sits behind the `TextEditor` with the same frame, so the text view it wants is the one that covers it.
private struct EditorPasteboardInterceptor: NSViewRepresentable {
    let onFiles: ([URL]) -> Void
    let onImage: ((Data, UTType) -> Void)?

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(handler: EditorPasteboardHandler(onFiles: onFiles, onImage: onImage))
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.handler.onFiles = onFiles
        view.handler.onImage = onImage
        view.attach()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.detach()
    }

    final class AnchorView: NSView {
        let handler: EditorPasteboardHandler
        private weak var textView: NSTextView?

        init(handler: EditorPasteboardHandler) {
            self.handler = handler
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                // SwiftUI may add the text view after this anchor; look again once the current update is done.
                DispatchQueue.main.async { [weak self] in self?.attach() }
            }
        }

        override func layout() {
            super.layout()
            attach()
        }

        func attach() {
            guard let window, let found = coveringTextView(in: window) else { return }
            guard found !== textView else { return }
            detach()
            textView = found
            EditorPasteboardHook.attach(handler, to: found)
        }

        func detach() {
            if let textView { EditorPasteboardHook.detach(from: textView) }
            textView = nil
        }

        /// The rich, editable text view whose frame overlaps this anchor's the most.
        private func coveringTextView(in window: NSWindow) -> NSTextView? {
            guard let root = window.contentView else { return nil }
            let frame = convert(bounds, to: nil)
            guard frame.width > 0, frame.height > 0 else { return nil }
            var best: (view: NSTextView, area: CGFloat)?
            func visit(_ view: NSView) {
                if let textView = view as? NSTextView, textView.isRichText, textView.isEditable {
                    let container = textView.enclosingScrollView ?? textView
                    let overlap = container.convert(container.bounds, to: nil).intersection(frame)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > (best?.area ?? 0) { best = (textView, area) }
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            return best?.view
        }
    }
}

/// What the editor does with a pasteboard that carries files or a bare image.
@MainActor final class EditorPasteboardHandler: NSObject {
    var onFiles: ([URL]) -> Void
    var onImage: ((Data, UTType) -> Void)?

    init(onFiles: @escaping ([URL]) -> Void, onImage: ((Data, UTType) -> Void)?) {
        self.onFiles = onFiles
        self.onImage = onImage
    }

    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// Files first: a Finder copy also carries the file's name as text and its icon as an image.
    func read(_ pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            onFiles(urls)
            return true
        }
        if let onImage, Self.imageTypes.contains(type), let data = pasteboard.data(forType: type) {
            if type == .png {
                onImage(data, .png)
            } else if let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                onImage(png, .png)
            } else {
                return false
            }
            return true
        }
        return false
    }
}

/// SwiftUI's rich text editor is its own `NSTextView` subclass, which reads pastes and drops alike through
/// `readSelection(from:type:)`; a file arrives there as its path, as text. SwiftUI offers no hook at that point,
/// so this adds one to that class: text views that carry a handler (the composer's) hand files and bare images
/// to it, and every other instance runs the original implementation unchanged.
@MainActor enum EditorPasteboardHook {
    private nonisolated(unsafe) static let handlerKey = UnsafeRawPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    private static var patchedClasses: Set<ObjectIdentifier> = []

    static func attach(_ handler: EditorPasteboardHandler, to textView: NSTextView) {
        patch(editorClass(of: textView))
        objc_setAssociatedObject(textView, handlerKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func detach(from textView: NSTextView) {
        objc_setAssociatedObject(textView, handlerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    nonisolated static func handler(of textView: NSTextView) -> EditorPasteboardHandler? {
        objc_getAssociatedObject(textView, handlerKey) as? EditorPasteboardHandler
    }

    /// The class to patch: the text view's own, not a key-value-observing subclass the runtime may have put in front.
    private static func editorClass(of textView: NSTextView) -> AnyClass {
        var cls: AnyClass = object_getClass(textView) ?? NSTextView.self
        while NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let superclass = class_getSuperclass(cls) {
            cls = superclass
        }
        return cls
    }

    private static func patch(_ cls: AnyClass) {
        guard cls != NSTextView.self, patchedClasses.insert(ObjectIdentifier(cls)).inserted else { return }

        let readSelector = #selector(NSTextView.readSelection(from:type:))
        typealias Read = @convention(c) (NSTextView, Selector, NSPasteboard, NSPasteboard.PasteboardType) -> Bool
        override(readSelector, in: cls) { (original: Read) in
            let read: @convention(block) (NSTextView, NSPasteboard, NSPasteboard.PasteboardType) -> Bool = {
                textView, pasteboard, type in
                if let handler = handler(of: textView),
                   MainActor.assumeIsolated({ handler.read(pasteboard, type: type) }) {
                    return true
                }
                return original(textView, readSelector, pasteboard, type)
            }
            return read
        }

        // Bare images become readable, after every type the editor reads itself, so rich text keeps winning.
        let typesSelector = #selector(getter: NSTextView.readablePasteboardTypes)
        typealias Types = @convention(c) (NSTextView, Selector) -> [NSPasteboard.PasteboardType]
        override(typesSelector, in: cls) { (original: Types) in
            let types: @convention(block) (NSTextView) -> [NSPasteboard.PasteboardType] = { textView in
                let types = original(textView, typesSelector)
                guard let handler = handler(of: textView), MainActor.assumeIsolated({ handler.onImage != nil })
                else { return types }
                return types + EditorPasteboardHandler.imageTypes.filter { !types.contains($0) }
            }
            return types
        }
    }

    /// Replaces `selector` on `cls` only: if the class merely inherits it, an override is added, so `NSTextView`
    /// itself is never changed. `make` gets the implementation that was in effect.
    private static func override<Original>(_ selector: Selector, in cls: AnyClass, _ make: (Original) -> Any) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement = imp_implementationWithBlock(make(original))
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }
}

#endif
