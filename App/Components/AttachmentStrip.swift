import JMAPKit
import MailPrivacy
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// How far a download has come. App-local: the attachment store's own progress type lives in GoodMailCore,
/// which these components don't depend on; the app adapts it in one line.
struct AttachmentProgress: Equatable {
    var received: Int
    var expected: Int?
}

/// What the reading pane's attachment strip needs from the attachment store. GoodMailCore's `AttachmentCenter`
/// conforms in the app; previews and the render harness use stand-ins.
///
/// Decrypted copies on disk only ever come from `previewURL(for:)`: temporary files the store owns and deletes once
/// they are released. Saving streams into the file the user picked (`write`), or hands over bytes (`data`).
@MainActor protocol AttachmentActions: Sendable {
    func isCached(_ part: EmailBodyPart) async -> Bool
    func previewURL(for part: EmailBodyPart) async throws -> URL
    func release(_ url: URL)
    func data(for part: EmailBodyPart) async throws -> Data
    func attachmentProgress(blobId: String) -> AttachmentProgress?
    func write(_ part: EmailBodyPart, to destination: URL) async throws
}

/// A message's attachments as a row of chips. A tap opens Quick Look, which brings its own Share; the context
/// menu offers Open, Save… and Share, and on the Mac a chip can be dragged out. Files are fetched on demand and
/// kept in the encrypted cache, so the chips show download progress and which files open offline.
struct AttachmentStrip: View {
    private let parts: [EmailBodyPart]
    private let actions: any AttachmentActions

    @State private var model = AttachmentStripModel()
    #if os(iOS)
    @State private var export: ExportedAttachment?
    #endif

    init(parts: [EmailBodyPart], actions: any AttachmentActions) {
        self.parts = parts
        self.actions = actions
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    chip(for: part)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .quickLookPreview(previewBinding)
        .task(id: parts.compactMap(\.blobId)) { await model.refreshCached(parts, actions: actions) }
        .alert(
            model.problem?.title ?? "",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } }),
            presenting: model.problem
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
        #if os(iOS)
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            item: export, contentTypes: [.data], defaultFilename: export?.filename
        ) { [filename = export?.filename] result in
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                model.problem = AttachmentProblem(title: "Couldn't save \(filename ?? "the file")",
                                                  message: error.localizedDescription)
            }
        }
        #endif
    }

    private func chip(for part: EmailBodyPart) -> some View {
        let name = Self.filename(of: part)
        return AttachmentChip(
            name: name, size: part.size, typeIdentifier: part.type.flatMap { UTType(mimeType: $0)?.identifier },
            state: state(of: part), onRemove: nil
        )
        .onTapGesture { model.open(part, from: actions) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens a preview")
        .contextMenu {
            Button("Open", systemImage: "eye") { model.open(part, from: actions) }
            Button("Save…", systemImage: "square.and.arrow.down") { save(part) }
            ShareLink(item: AttachmentTransfer(part: part, filename: name, actions: actions),
                      preview: SharePreview(name)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        #if os(macOS)
        .draggable(AttachmentTransfer(part: part, filename: name, actions: actions))
        #endif
    }

    /// Quick Look on the Mac keeps this binding while its panel is open, even after the strip went away, so it
    /// holds the model weakly: the model has to go with the strip to release the copy.
    private var previewBinding: Binding<URL?> {
        let model = model
        return Binding(get: { [weak model] in model?.previewURL }, set: { [weak model] url in
            if url == nil { model?.closePreview() }
        })
    }

    private func state(of part: EmailBodyPart) -> AttachmentChip.State {
        guard let blobId = part.blobId else { return .ready }
        if let failure = model.failures[blobId] { return .failed(failure) }
        if let progress = actions.attachmentProgress(blobId: blobId) {
            let fraction = progress.expected.flatMap { $0 > 0 ? Double(progress.received) / Double($0) : nil }
            return .downloading(fraction)
        }
        return model.cachedBlobIDs.contains(blobId) ? .cached : .ready
    }

    private func save(_ part: EmailBodyPart) {
        let model = model
        #if os(macOS)
        // The store streams the file into place, so a large attachment never sits in memory as a whole.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.filename(of: part)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        Task {
            guard await panel.begin() == .OK, let destination = panel.url else { return }
            do {
                try await actions.write(part, to: destination)
                model.markAvailable(part)
            } catch {
                model.report(error, for: part, saving: true)
            }
        }
        #else
        Task {
            do {
                let data = try await actions.data(for: part)
                model.markAvailable(part)
                export = ExportedAttachment(data: data, filename: Self.filename(of: part))
            } catch {
                model.report(error, for: part)
            }
        }
        #endif
    }

    /// Names come from the sender, so they go through `SafeFilename` before they are shown or written.
    static func filename(of part: EmailBodyPart) -> String {
        SafeFilename.make(part.name, mimeType: part.type)
    }
}

/// The strip's state, and the decrypted copy Quick Look shows (D23). The copy goes back to the store when the
/// preview closes, when another one replaces it, and when the strip goes away and this model with it: a Mac panel
/// stays open while another message is shown, and a download can end after its message was left. Only the strip's
/// state holds the model; the download it waits for and Quick Look's binding hold it weakly.
@MainActor @Observable final class AttachmentStripModel {
    private(set) var cachedBlobIDs: Set<String> = []
    private(set) var failures: [String: String] = [:]
    var problem: AttachmentProblem?
    private var preview: PreviewCopy?
    @ObservationIgnored private var opening: Task<Void, Never>?

    private struct PreviewCopy {
        let url: URL
        let store: any AttachmentActions
    }

    var previewURL: URL? { preview?.url }

    /// Fetches the decrypted copy and shows it; a later tap wins, and a copy nobody shows any more goes back.
    func open(_ part: EmailBodyPart, from store: any AttachmentActions) {
        opening?.cancel()
        opening = Task { [weak self] in
            do {
                let url = try await store.previewURL(for: part)
                guard let self, !Task.isCancelled else {
                    store.release(url)
                    return
                }
                markAvailable(part)
                show(url, from: store)
            } catch {
                guard !Task.isCancelled else { return }
                self?.report(error, for: part)
            }
        }
    }

    func closePreview() {
        show(nil, from: nil)
    }

    private func show(_ url: URL?, from store: (any AttachmentActions)?) {
        if let preview, preview.url != url { preview.store.release(preview.url) }
        preview = url.flatMap { url in store.map { PreviewCopy(url: url, store: $0) } }
    }

    isolated deinit {
        opening?.cancel()
        if let preview { preview.store.release(preview.url) }
    }

    func refreshCached(_ parts: [EmailBodyPart], actions: any AttachmentActions) async {
        var cached: Set<String> = []
        for part in parts {
            guard let blobId = part.blobId else { continue }
            if await actions.isCached(part) { cached.insert(blobId) }
        }
        cachedBlobIDs = cached
    }

    func markAvailable(_ part: EmailBodyPart) {
        guard let blobId = part.blobId else { return }
        failures[blobId] = nil
        cachedBlobIDs.insert(blobId)
    }

    /// A save on the Mac can fail after the download worked (no room, no permission), so it is reported as a save,
    /// and the chip keeps its state.
    func report(_ error: any Error, for part: EmailBodyPart, saving: Bool = false) {
        guard !(error is CancellationError) else { return }
        let name = AttachmentStrip.filename(of: part)
        if !saving, let blobId = part.blobId { failures[blobId] = "Couldn't download" }
        problem = AttachmentProblem(title: saving ? "Couldn't save \(name)" : "Couldn't download \(name)",
                                    message: error.localizedDescription)
    }
}

struct AttachmentProblem {
    var title: String
    var message: String
}

/// A received attachment for the share sheet or a drag: the decrypted temporary copy is made only when the
/// receiver asks for the file, and handed back to the store after ten minutes, the time the Mac keeps a closed
/// preview's copy. The receiver gets its own copy (`SentTransferredFile` without access to the original).
///
/// It is offered as its own type when that is a common one, so share sheets and drop targets see what it is (Save
/// Image wants an image, a PDF reader a PDF), and as plain data otherwise.
struct AttachmentTransfer: Transferable {
    let part: EmailBodyPart
    let filename: String
    let actions: any AttachmentActions

    /// By the name's extension, which `SafeFilename` takes from the MIME type when the sender gave none, since the
    /// receiver goes by the name too; else by the MIME type.
    var contentType: UTType {
        let fileExtension = (filename as NSString).pathExtension
        if let type = UTType(filenameExtension: fileExtension), !type.isDynamic { return type }
        if let mimeType = part.type, let type = UTType(mimeType: mimeType), !type.isDynamic { return type }
        return .data
    }

    static var transferRepresentation: some TransferRepresentation {
        CommonAttachmentTypes()
        FileRepresentation(exportedContentType: .data, exporting: export)
            .suggestedFileName { $0.filename }
    }

    fileprivate static func export(_ item: AttachmentTransfer) async throws -> SentTransferredFile {
        let url = try await item.actions.previewURL(for: item.part)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(600))
            item.actions.release(url)
        }
        return SentTransferredFile(url)
    }
}

/// The types share sheets and drop targets act on, each offered only for an attachment of that type.
private struct CommonAttachmentTypes: TransferRepresentation {
    typealias Item = AttachmentTransfer

    @TransferRepresentationBuilder<AttachmentTransfer> var body: some TransferRepresentation<AttachmentTransfer> {
        AttachmentFile(.jpeg)
        AttachmentFile(.png)
        AttachmentFile(.heic)
        AttachmentFile(.gif)
        AttachmentFile(.tiff)
        AttachmentFile(.webP)
        AttachmentFile(.pdf)
        CommonMediaTypes()
    }
}

private struct CommonMediaTypes: TransferRepresentation {
    typealias Item = AttachmentTransfer

    @TransferRepresentationBuilder<AttachmentTransfer> var body: some TransferRepresentation<AttachmentTransfer> {
        AttachmentFile(.mpeg4Movie)
        AttachmentFile(.quickTimeMovie)
        AttachmentFile(.mp3)
        AttachmentFile(.mpeg4Audio)
        AttachmentFile(.vCard)
        AttachmentFile(.calendarEvent)
        AttachmentFile(.zip)
        AttachmentFile(.plainText)
    }
}

private struct AttachmentFile: TransferRepresentation {
    typealias Item = AttachmentTransfer

    let contentType: UTType

    init(_ contentType: UTType) {
        self.contentType = contentType
    }

    var body: some TransferRepresentation<AttachmentTransfer> {
        FileRepresentation(exportedContentType: contentType, exporting: AttachmentTransfer.export)
            .suggestedFileName { $0.filename }
            .exportingCondition { [contentType] in $0.contentType.conforms(to: contentType) }
    }
}

#if os(iOS)
/// The bytes of an attachment for `fileExporter`, which writes them where the user picked.
struct ExportedAttachment: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { $0.data }
            .suggestedFileName { $0.filename }
    }
}
#endif
