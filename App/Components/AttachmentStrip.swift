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

    @State private var previewURL: URL?
    @State private var cachedBlobIDs: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var downloadProblem: DownloadProblem?
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
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { old, _ in
            if let old { actions.release(old) }
        }
        .task(id: parts.compactMap(\.blobId)) { await refreshCached() }
        .alert(
            downloadProblem?.title ?? "",
            isPresented: Binding(get: { downloadProblem != nil }, set: { if !$0 { downloadProblem = nil } }),
            presenting: downloadProblem
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
                downloadProblem = DownloadProblem(title: "Couldn't save \(filename ?? "the file")",
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
        .onTapGesture { open(part) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens a preview")
        .contextMenu {
            Button("Open", systemImage: "eye") { open(part) }
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

    private func state(of part: EmailBodyPart) -> AttachmentChip.State {
        guard let blobId = part.blobId else { return .ready }
        if let failure = failures[blobId] { return .failed(failure) }
        if let progress = actions.attachmentProgress(blobId: blobId) {
            let fraction = progress.expected.flatMap { $0 > 0 ? Double(progress.received) / Double($0) : nil }
            return .downloading(fraction)
        }
        return cachedBlobIDs.contains(blobId) ? .cached : .ready
    }

    private func refreshCached() async {
        var cached: Set<String> = []
        for part in parts {
            guard let blobId = part.blobId else { continue }
            if await actions.isCached(part) { cached.insert(blobId) }
        }
        cachedBlobIDs = cached
    }

    private func open(_ part: EmailBodyPart) {
        Task {
            do {
                let url = try await actions.previewURL(for: part)
                markAvailable(part)
                previewURL = url
            } catch {
                report(error, for: part)
            }
        }
    }

    private func save(_ part: EmailBodyPart) {
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
                markAvailable(part)
            } catch {
                report(error, for: part, saving: true)
            }
        }
        #else
        Task {
            do {
                let data = try await actions.data(for: part)
                markAvailable(part)
                export = ExportedAttachment(data: data, filename: Self.filename(of: part))
            } catch {
                report(error, for: part)
            }
        }
        #endif
    }

    private func markAvailable(_ part: EmailBodyPart) {
        guard let blobId = part.blobId else { return }
        failures[blobId] = nil
        cachedBlobIDs.insert(blobId)
    }

    /// A save on the Mac can fail after the download worked (no room, no permission), so it is reported as a save,
    /// and the chip keeps its state.
    private func report(_ error: any Error, for part: EmailBodyPart, saving: Bool = false) {
        guard !(error is CancellationError) else { return }
        let name = Self.filename(of: part)
        if !saving, let blobId = part.blobId { failures[blobId] = "Couldn't download" }
        downloadProblem = DownloadProblem(title: saving ? "Couldn't save \(name)" : "Couldn't download \(name)",
                                          message: error.localizedDescription)
    }

    /// Names come from the sender, so they go through `SafeFilename` before they are shown or written.
    static func filename(of part: EmailBodyPart) -> String {
        SafeFilename.make(part.name, mimeType: part.type)
    }
}

private struct DownloadProblem {
    var title: String
    var message: String
}

/// A received attachment for the share sheet or a drag: the decrypted temporary copy is made only when the
/// receiver asks for the file, and handed back to the store after ten minutes, the time the Mac keeps a closed
/// preview's copy. The receiver gets its own copy (`SentTransferredFile` without access to the original).
struct AttachmentTransfer: Transferable {
    let part: EmailBodyPart
    let filename: String
    let actions: any AttachmentActions

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            let url = try await item.actions.previewURL(for: item.part)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(600))
                item.actions.release(url)
            }
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.filename }
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
