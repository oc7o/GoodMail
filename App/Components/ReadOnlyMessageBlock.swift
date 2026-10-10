import MailCompose
import MailPrivacy
import SwiftUI

/// HTML or text the composer shows but never edits: the quoted original, the signature, a draft from another client
/// in preview mode. It is rendered like a received message (`MessageRenderer` with `.blockAll`, in the CSP-locked
/// `MessageWebView`), so it loads nothing from the network; quoted `cid:` images come from `inlineImage`.
///
/// Collapsible blocks start closed, as "Show quoted text" beside the title (the attribution line). The web view is
/// only made once the block is open, and the sanitizing render runs off the main actor, since quotes can be
/// megabytes long.
///
/// HTML that carries no styling of its own (a signature, or a quote the editor itself could have written) follows
/// light and dark like the text above it; styled mail keeps the white page it was written for, as in the reading
/// pane.
struct ReadOnlyMessageBlock: View {
    private let title: String?
    private let html: String?
    private let text: String?
    private let isCollapsible: Bool
    private let inlineImage: @MainActor (String) async -> (data: Data, mimeType: String)?

    @State private var isExpanded = false
    @State private var rendering: Rendering?
    @State private var height: CGFloat = 40

    init(
        title: String?, html: String?, text: String?, isCollapsible: Bool,
        inlineImage: @escaping @MainActor (String) async -> (data: Data, mimeType: String)?
    ) {
        self.title = title
        self.html = html
        self.text = text
        self.isCollapsible = isCollapsible
        self.inlineImage = inlineImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCollapsible {
                disclosure
            } else if let title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if showsContent, let rendering, rendering.source == source {
                MessageWebView(html: rendering.html, policy: .blockAll, height: $height, inlineImage: inlineImage)
                    .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: RenderKey(source: source, isShown: showsContent)) {
            let source = source
            guard showsContent, rendering?.source != source else { return }
            let html = await Task.detached(priority: .userInitiated) {
                Self.render(source)
            }.value
            rendering = Rendering(source: source, html: html)
        }
    }

    private var source: Source {
        Source(html: html, text: text)
    }

    private var showsContent: Bool {
        !isCollapsible || isExpanded
    }

    private var disclosure: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                if let title {
                    Text(title)
                        .lineLimit(isExpanded ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(isExpanded ? "Hide quoted text" : "Show quoted text")
                    .foregroundStyle(.tint)
                    .frame(maxWidth: title == nil ? .infinity : nil, alignment: .leading)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide quoted text" : "Show quoted text")
        .accessibilityValue(title ?? "")
    }

    private nonisolated static func render(_ source: Source) -> String {
        let html = MessageRenderer.render(source.parts, policy: .blockAll).html
        guard let original = source.html, original.utf8.count <= 100_000,
              MailBodyHTMLReader.read(original).dropped.isEmpty
        else { return html }
        return html.replacingOccurrences(of: "</head>", with: adaptiveStyle + "</head>")
    }

    /// Gives the document the system's light or dark text and background, over the renderer's white page.
    private nonisolated static let adaptiveStyle = "<style>:root { color-scheme: light dark; } "
        + "html { background: transparent !important; color: CanvasText !important; }</style>"

    private struct Source: Equatable, Sendable {
        var html: String?
        var text: String?

        var parts: [MessagePart] {
            if let html { return [MessagePart(kind: .html, content: html)] }
            return text.map { [MessagePart(kind: .plainText, content: $0)] } ?? []
        }
    }

    private struct Rendering {
        var source: Source
        var html: String
    }

    private struct RenderKey: Equatable {
        var source: Source
        var isShown: Bool
    }
}
