import Foundation
import JMAPKit
import MailPrivacy
import MailStore
import Observation

/// Why an attachment couldn't be provided, besides the errors of the server and the store.
public enum AttachmentDownloadError: Error, Equatable, Sendable, LocalizedError {
    /// The part has no blob to download, such as one the server couldn't parse.
    case notDownloadable(name: String)
    /// The download ended before the whole file arrived.
    case incomplete(name: String)

    public var errorDescription: String? {
        switch self {
        case .notDownloadable(let name): "“\(name)” can't be downloaded."
        case .incomplete(let name): "“\(name)” didn't download completely."
        }
    }
}

/// Received attachments for opening, sharing and saving.
///
/// Everything comes from the encrypted attachment cache; an attachment that isn't there is downloaded into it
/// first (C31), so whatever was opened, shared or saved once opens again offline. Decrypted files exist only as
/// `TemporaryFiles` copies. Each blob downloads once at a time, however many ask for it, with its progress in
/// `downloads`.
@MainActor
@Observable
public final class AttachmentCenter {
    public struct Progress: Equatable, Sendable {
        public var received: Int
        /// The server's Content-Length, else the size the email gives.
        public var expected: Int?

        public init(received: Int, expected: Int?) {
            self.received = received
            self.expected = expected
        }
    }

    /// Downloads under way, by blob id.
    public private(set) var downloads: [String: Progress] = [:]
    @ObservationIgnored private var running: [String: (id: UUID, task: Task<Void, any Error>)] = [:]
    private let client: JMAPClient
    private let store: MailStore
    private let files: TemporaryFiles

    /// Bytes between two progress reports, so that a large download doesn't update the UI for every chunk.
    nonisolated private static let progressStep = 256 << 10

    public init(client: JMAPClient, store: MailStore, files: TemporaryFiles = .shared) {
        self.client = client
        self.store = store
        self.files = files
    }

    public func progress(blobId: String) -> Progress? {
        downloads[blobId]
    }

    /// Whether the attachment opens without the network.
    public func isCached(_ part: EmailBodyPart) async -> Bool {
        guard let blobId = part.blobId else { return false }
        return (try? await store.isAttachmentCached(blobId: blobId)) == true
    }

    /// A decrypted copy for Quick Look (D23), named safely after the attachment. Hand it back with `release(_:)`
    /// once the preview closes.
    public func previewURL(for part: EmailBodyPart) async throws -> URL {
        let name = SafeFilename.make(part.name, mimeType: part.type)
        let store = store, files = files
        return try await fromCache(part) { blobId in
            try await files.copy(named: name) { handle in
                try await store.exportAttachment(blobId: blobId, into: handle)
            }
        }
    }

    public func release(_ url: URL) {
        let files = files
        Task { await files.release(url) }
    }

    /// The attachment's bytes, e.g. for sharing or `fileExporter`.
    public func data(for part: EmailBodyPart) async throws -> Data {
        try await fromCache(part) { blobId in
            guard let data = try await self.store.cachedAttachment(blobId: blobId) else {
                throw MailStoreError.attachmentNotCached(blobId)
            }
            return data
        }
    }

    /// Saves the attachment at `destination`, such as a save panel's choice, replacing what is there.
    ///
    /// The attachment goes into a `TemporaryFiles` copy first, which then takes the destination's place in one
    /// step, so a failure halfway leaves a file already at `destination` as it was.
    public func write(_ part: EmailBodyPart, to destination: URL) async throws {
        let store = store, files = files
        let copy = try await fromCache(part) { blobId in
            try await files.copy(named: destination.lastPathComponent) { handle in
                try await store.exportAttachment(blobId: blobId, into: handle)
            }
        }
        let isScoped = destination.startAccessingSecurityScopedResource()
        defer { if isScoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try await Self.replace(destination, with: copy)
        } catch {
            await files.discard(copy)
            throw error
        }
        await files.discard(copy)
    }

    /// Stops a download. Nothing of it stays in the cache, and whoever waits for it gets an error.
    public func cancelDownload(blobId: String) {
        guard let download = running.removeValue(forKey: blobId) else { return }
        download.task.cancel()
        downloads[blobId] = nil
    }

    // MARK: Downloading

    /// Runs `read` on the cached attachment, downloading it first if needed.
    private func fromCache<Result>(
        _ part: EmailBodyPart, _ read: (String) async throws -> Result
    ) async throws -> Result {
        guard let blobId = part.blobId else {
            throw AttachmentDownloadError.notDownloadable(name: Self.name(of: part))
        }
        let isCached = running[blobId] == nil ? (try? await store.isAttachmentCached(blobId: blobId)) == true : false
        if !isCached { try await download(part, blobId: blobId) }
        do {
            return try await read(blobId)
        } catch MailStoreError.attachmentNotCached {
            // Evicted in between, which only a cache full of attachments used more recently does.
            try await download(part, blobId: blobId)
            return try await read(blobId)
        }
    }

    /// Downloads into the cache, or waits for the download of the blob that is already running.
    private func download(_ part: EmailBodyPart, blobId: String) async throws {
        if let download = running[blobId] { return try await download.task.value }
        let id = UUID()
        downloads[blobId] = Progress(received: 0, expected: part.size)
        let task = Task { try await self.performDownload(part, blobId: blobId, id: id) }
        running[blobId] = (id, task)
        try await task.value
    }

    private func performDownload(_ part: EmailBodyPart, blobId: String, id: UUID) async throws {
        defer {
            if running[blobId]?.id == id {
                running[blobId] = nil
                downloads[blobId] = nil
            }
        }
        let type = part.type ?? "application/octet-stream"
        let download = try await client.downloadStream(
            blobId: blobId, type: type, name: SafeFilename.make(part.name, mimeType: part.type))
        if running[blobId]?.id == id {
            downloads[blobId] = Progress(received: 0, expected: download.expectedLength ?? part.size)
        }
        let writer = try await store.beginAttachment(blobId: blobId, type: type)
        do {
            let received = try await Self.copy(download.chunks, into: writer) { [weak self] received in
                guard let self, running[blobId]?.id == id else { return }
                downloads[blobId]?.received = received
            }
            // A stream ends without an error when its task is cancelled, so its end alone proves nothing.
            try Task.checkCancellation()
            if let expected = download.expectedLength, received != expected {
                throw AttachmentDownloadError.incomplete(name: Self.name(of: part))
            }
            try await writer.finish(evictingBeyond: MailStore.attachmentCacheLimit)
        } catch {
            await writer.abort()
            // Another write of the same attachment, such as prefetching storing it whole, stopped this one. If
            // that write is done, the attachment is there all the same.
            if error as? MailStoreError == .writerClosed, (try? await store.isAttachmentCached(blobId: blobId)) == true {
                return
            }
            throw error
        }
    }

    /// Appends the chunks to the cache off the main actor, reporting progress after the first chunk, then every
    /// `progressStep` bytes, and at the end. Returns the byte count.
    nonisolated private static func copy(
        _ chunks: AsyncThrowingStream<Data, any Error>, into writer: BlobWriter,
        progress: @escaping @MainActor @Sendable (Int) -> Void
    ) async throws -> Int {
        var received = 0
        var reported = 0
        for try await chunk in chunks {
            try await writer.append(chunk)
            received += chunk.count
            if reported == 0 || received - reported >= progressStep {
                reported = received
                await progress(received)
            }
        }
        await progress(received)
        return received
    }

    // MARK: Saving

    /// Puts `copy` in the place of `destination`: whatever is there stays whole until it is swapped out. That only
    /// works within one volume, so for a destination on another one, the copy is first copied next to it, into the
    /// item-replacement folder the system keeps on that volume.
    nonisolated private static func replace(_ destination: URL, with copy: URL) async throws {
        let fileManager = FileManager.default
        do {
            _ = try fileManager.replaceItemAt(destination, withItemAt: copy)
        } catch where isCrossDevice(error) {
            let staging = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
            defer { try? fileManager.removeItem(at: staging) }
            let staged = staging.appending(path: copy.lastPathComponent)
            try fileManager.copyItem(at: copy, to: staged)
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        }
    }

    nonisolated static func isCrossDevice(_ error: any Error) -> Bool {
        var error: NSError? = error as NSError
        while let current = error {
            if current.domain == NSPOSIXErrorDomain, current.code == Int(EXDEV) { return true }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func name(of part: EmailBodyPart) -> String {
        part.name ?? "Attachment"
    }
}
