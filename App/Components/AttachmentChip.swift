import SwiftUI
import UniformTypeIdentifiers

/// One attached file, as content (never glass): a type icon, the name truncated in the middle, the size, and
/// what is happening to it. The composer and the reading pane both use it; whoever shows it decides what a tap
/// does (retry, re-attach, open).
struct AttachmentChip: View {
    enum State: Equatable {
        case ready
        /// Progress from 0 to 1, or nil while the size is unknown.
        case uploading(Double?)
        case failed(String)
        case downloading(Double?)
        /// Kept in the encrypted attachment cache, so it opens offline.
        case cached
        /// Its bytes are gone (the attachment store was reset): the user has to attach it again.
        case missing
    }

    private let name: String
    private let size: Int?
    private let typeIdentifier: String?
    private let state: State
    private let onRemove: (() -> Void)?

    init(name: String, size: Int?, typeIdentifier: String?, state: State, onRemove: (() -> Void)?) {
        self.name = name
        self.size = size
        self.typeIdentifier = typeIdentifier
        self.state = state
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                icon
                    .font(.title3)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .font(.subheadline)
                .frame(maxWidth: 220, alignment: .leading)
                status
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(detail)")
            if let onRemove {
                Button("Remove \(name)", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, onRemove == nil ? 12 : 6)
        .padding(.vertical, 6)
        .background {
            ZStack {
                Capsule(style: .circular).fill(.fill.secondary)
                if isProblem { Capsule(style: .circular).strokeBorder(.red.opacity(0.5)) }
            }
        }
        .contentShape(Capsule(style: .circular))
        // As wide as its content, up to the name's limit, wherever it is placed.
        .fixedSize(horizontal: true, vertical: false)
        .help(helpText)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: Self.symbolName(for: typeIdentifier)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .uploading(let progress), .downloading(let progress):
            AttachmentProgressRing(progress: progress)
        case .cached:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tertiary)
        case .ready, .failed, .missing:
            EmptyView()
        }
    }

    private var sizeText: String? {
        size.map { Int64($0).formatted(.byteCount(style: .file)) }
    }

    private var detail: String {
        switch state {
        case .ready: sizeText ?? "Attachment"
        case .uploading(let progress): progress.map { "Uploading \(Int(($0 * 100).rounded())) %" } ?? "Uploading…"
        case .failed(let message): message
        case .downloading(let progress): progress.map { "Downloading \(Int(($0 * 100).rounded())) %" } ?? "Downloading…"
        case .cached: [sizeText, "available offline"].compactMap { $0 }.joined(separator: " · ")
        case .missing: "Re-attach"
        }
    }

    private var helpText: String {
        switch state {
        case .failed(let message): message
        case .missing: "This file is no longer on this device. Attach it again."
        default: name
        }
    }

    private var isProblem: Bool {
        switch state {
        case .failed, .missing: true
        default: false
        }
    }

    /// An SF Symbol for the file's kind, from its type identifier (or MIME type, which some callers have instead).
    static func symbolName(for typeIdentifier: String?) -> String {
        guard let typeIdentifier,
              let type = UTType(typeIdentifier) ?? UTType(mimeType: typeIdentifier)
        else { return "doc" }
        let symbols: [(UTType, String)] = [
            (.pdf, "doc.richtext"), (.image, "photo"), (.movie, "film"), (.audio, "waveform"),
            (.archive, "doc.zipper"), (.spreadsheet, "tablecells"), (.presentation, "rectangle.on.rectangle.angled"),
            (.emailMessage, "envelope"), (.vCard, "person.crop.rectangle"), (.calendarEvent, "calendar"),
            (.sourceCode, "chevron.left.forwardslash.chevron.right"), (.text, "doc.text"),
        ]
        return symbols.first { type.conforms(to: $0.0) }?.1 ?? "doc"
    }
}

/// A small determinate ring, or a spinner while the total is unknown. Drawn by hand so it looks the same on
/// both platforms (a determinate circular `ProgressView` isn't a ring everywhere).
struct AttachmentProgressRing: View {
    let progress: Double?

    var body: some View {
        Group {
            if let progress {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(progress, 1)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .animation(.linear(duration: 0.2), value: progress)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
