import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

/// The ways to attach something besides pasting and dropping (§2.5): Choose File…, Photos…, and the document
/// scanner on iOS; on the Mac, Continuity Camera's Import from iPhone (`ImportFromDevicesCommands` in the File
/// menu). Everything arrives as a file or as data, which the composer attaches.
@MainActor
@Observable
final class AttachmentPickers {
    var isImportingFiles = false
    var isPickingPhotos = false
    var isScanning = false
    var photos: [PhotosPickerItem] = []
}

/// The paperclip menu.
struct AttachMenu: View {
    let pickers: AttachmentPickers

    var body: some View {
        Menu {
            Button("Choose File…", systemImage: "doc") { pickers.isImportingFiles = true }
            Button("Photos…", systemImage: "photo.on.rectangle") { pickers.isPickingPhotos = true }
            #if os(iOS)
            if VNDocumentCameraViewController.isSupported {
                Button("Scan Document", systemImage: "doc.viewfinder") { pickers.isScanning = true }
            }
            #endif
        } label: {
            Label("Attach", systemImage: "paperclip")
        }
        .menuIndicator(.hidden)
        .help("Attach files or photos")
    }
}

extension View {
    /// Presents the pickers of `pickers`. Files arrive as URLs (security-scoped from the file importer, temporary
    /// copies from Photos, which the caller deletes once attached); scans and Continuity Camera captures as data.
    func attachmentPickers(
        _ pickers: AttachmentPickers, onFiles: @escaping ([URL]) -> Void,
        onData: @escaping (Data, String, UTType) -> Void
    ) -> some View {
        modifier(AttachmentPickerPresenter(pickers: pickers, onFiles: onFiles, onData: onData))
    }
}

private struct AttachmentPickerPresenter: ViewModifier {
    @Bindable var pickers: AttachmentPickers
    let onFiles: ([URL]) -> Void
    let onData: (Data, String, UTType) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $pickers.isImportingFiles, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty { onFiles(urls) }
            }
            .photosPicker(isPresented: $pickers.isPickingPhotos, selection: $pickers.photos,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: pickers.photos) { _, items in
                guard !items.isEmpty else { return }
                pickers.photos = []
                Task {
                    var files: [URL] = []
                    for item in items {
                        if let picked = try? await item.loadTransferable(type: PickedFile.self) { files.append(picked.url) }
                    }
                    if !files.isEmpty { onFiles(files) }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $pickers.isScanning) {
                DocumentScanner { name, pdf in onData(pdf, name, .pdf) }
                    .ignoresSafeArea()
            }
            #else
            // Continuity Camera: File ▸ Import from iPhone or iPad sends photos and scans here.
            .importsItemProviders([.image, .pdf]) { providers in
                guard !providers.isEmpty else { return false }
                Task {
                    for provider in providers {
                        if let (data, type) = await Self.load(provider) {
                            onData(data, type.conforms(to: .pdf) ? "Scanned Document.pdf" : "Photo", type)
                        }
                    }
                }
                return true
            }
            #endif
    }

    #if os(macOS)
    private static func load(_ provider: NSItemProvider) async -> (Data, UTType)? {
        let types = provider.registeredContentTypes
        guard let type = types.first(where: { $0.conforms(to: .pdf) }) ?? types.first(where: { $0.conforms(to: .image) })
        else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data.map { ($0, type) })
            }
        }
    }
    #endif
}

/// A photo or video from the Photos picker, as a file: videos can be large, so they aren't read into memory.
/// The picker's file lasts only for the import, so it is copied to a folder of its own in the temporary
/// directory, which the composer empties once the file is attached.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try PickedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try PickedFile(copying: $0.file) }
    }

    private init(copying file: URL) throws {
        let folder = PickedFile.folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: file.lastPathComponent, directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: file, to: copy)
        url = copy
    }

    static let folder = FileManager.default.temporaryDirectory.appending(path: "Picked", directoryHint: .isDirectory)

    /// Deletes a copy once it is attached; URLs that aren't such copies are left alone.
    static func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == Self.folder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

#if os(iOS)
/// The system document scanner; the scanned pages arrive as one PDF.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: (String, Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// VisionKit calls its delegate on the main thread, without saying so to Swift.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner

        init(parent: DocumentScanner) {
            self.parent = parent
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
        ) {
            let title = scan.title.trimmingCharacters(in: .whitespaces)
            parent.onScan((title.isEmpty ? "Scanned Document" : title) + ".pdf", Self.pdf(of: scan))
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            parent.dismiss()
        }

        private static func pdf(of scan: VNDocumentCameraScan) -> Data {
            let first = scan.pageCount > 0 ? scan.imageOfPage(at: 0).size : CGSize(width: 612, height: 792)
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first))
            return renderer.pdfData { context in
                for index in 0..<scan.pageCount {
                    let image = scan.imageOfPage(at: index)
                    let bounds = CGRect(origin: .zero, size: image.size)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
        }
    }
}
#endif
