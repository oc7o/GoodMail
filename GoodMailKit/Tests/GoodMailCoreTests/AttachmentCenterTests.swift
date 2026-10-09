import DemoAccount
import Foundation
import JMAPKit
import MailStore
import Synchronization
import Testing
@testable import GoodMailCore

/// Received attachments against the demo account: the flight confirmation of e3 (180 KiB, three 64 KiB chunks)
/// and the invoice of e5.
@MainActor
struct AttachmentCenterTests {
    let transport = AttachmentCenterTestsTransport()
    let store: MailStore
    let root = TemporaryFilesTests.Root()
    let center: AttachmentCenter

    static let confirmationSize = 184_320

    init() throws {
        store = try MailStore()
        center = AttachmentCenter(
            client: JMAPClient(token: "demo", transport: transport, maxRetries: 0), store: store,
            files: root.files())
    }

    static func part(blobId: String? = "e3-file0", name: String? = "Flight confirmation.pdf", size: Int? = 184_320)
        -> EmailBodyPart
    {
        var json: [String: Any] = ["type": "application/pdf", "disposition": "attachment"]
        json["blobId"] = blobId
        json["name"] = name
        json["size"] = size
        return try! JMAPCoding.makeDecoder().decode(EmailBodyPart.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Waits for what the download does in the background, giving up after five seconds.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    // MARK: Opening

    @Test func openingDownloadsOnceIntoTheCacheAndHandsOutASafeCopy() async throws {
        let part = Self.part(name: "../../Flight\u{202E}fdp.exe")
        #expect(!(await center.isCached(part)))

        let url = try await center.previewURL(for: part)

        #expect(transport.server.downloadCount == 1)
        #expect(await center.isCached(part))
        #expect(try await store.cachedAttachment(blobId: "e3-file0")?.count == Self.confirmationSize)
        #expect(url.lastPathComponent == "Flightfdp.exe")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == root.url.standardizedFileURL)
        let copy = try Data(contentsOf: url)
        #expect(copy.count == Self.confirmationSize)
        #expect(copy.prefix(5) == Data("%PDF-".utf8))
        #if os(macOS)
        #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        #endif
        #expect(center.downloads.isEmpty)
    }

    @Test func openingAgainNeedsNoDownload() async throws {
        let first = try await center.previewURL(for: Self.part())
        transport.server.isOffline = true

        let second = try await center.previewURL(for: Self.part())

        #expect(transport.server.downloadCount == 1)
        #expect(first != second)
        #expect(try Data(contentsOf: second) == Data(contentsOf: first))
    }

    @Test func releasingDeletesTheCopy() async throws {
        let url = try await center.previewURL(for: Self.part())

        center.release(url)

        #expect(await eventually { !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) })
        #expect(await center.isCached(Self.part()))
    }

    @Test func purgingDeletesEveryCopy() async throws {
        _ = try await center.previewURL(for: Self.part())
        _ = try await center.previewURL(for: Self.part(blobId: "e5-file0", name: "Invoice-2041.pdf", size: 61_440))

        root.files().purgeAllNow()

        #expect(root.contents.isEmpty)
    }

    @Test func dataCachesWhatItDownloads() async throws {
        let invoice = Self.part(blobId: "e5-file0", name: "Invoice-2041.pdf", size: 61_440)

        let data = try await center.data(for: invoice)
        transport.server.isOffline = true

        #expect(data.count == 61_440)
        #expect(try await center.data(for: invoice) == data)
        #expect(try Data(contentsOf: try await center.previewURL(for: invoice)) == data)
        #expect(transport.server.downloadCount == 1)
    }

    @Test func simultaneousOpensShareOneDownload() async throws {
        transport.holdsDownloads = true
        let first = Task { try await center.previewURL(for: Self.part()) }
        let second = Task { try await center.data(for: Self.part()) }
        #expect(await eventually { center.progress(blobId: "e3-file0")?.received == 65_536 })

        transport.releaseDownloads()

        let url = try await first.value
        #expect(try await second.value == Data(contentsOf: url))
        #expect(transport.server.downloadCount == 1)
    }

    // MARK: Progress and failures

    @Test func progressIsReportedAndCancellingLeavesNothingCached() async throws {
        transport.holdsDownloads = true
        let opening = Task { try await center.previewURL(for: Self.part()) }

        #expect(await eventually {
            center.progress(blobId: "e3-file0") == .init(received: 65_536, expected: Self.confirmationSize)
        })
        center.cancelDownload(blobId: "e3-file0")

        await #expect(throws: (any Error).self) { try await opening.value }
        #expect(center.progress(blobId: "e3-file0") == nil)
        #expect(!(await center.isCached(Self.part())))
        #expect(try await store.attachmentCacheBytes() == 0)
        #expect(root.contents.isEmpty)

        // Nothing left over gets in the way of the next try.
        transport.holdsDownloads = false
        _ = try await center.previewURL(for: Self.part())
        #expect(transport.server.downloadCount == 2)
        #expect(await center.isCached(Self.part()))
    }

    @Test func aBrokenDownloadCachesNothing() async throws {
        transport.failsDownloads = true

        await #expect(throws: JMAPError.self) { try await center.previewURL(for: Self.part()) }

        #expect(!(await center.isCached(Self.part())))
        #expect(try await store.attachmentCacheBytes() == 0)
        #expect(center.downloads.isEmpty)
        #expect(root.contents.isEmpty)
    }

    @Test func aDownloadShorterThanAnnouncedCachesNothing() async throws {
        transport.truncatesDownloads = true

        await #expect(throws: AttachmentDownloadError.incomplete(name: "Flight confirmation.pdf")) {
            try await center.data(for: Self.part())
        }
        #expect(!(await center.isCached(Self.part())))
    }

    @Test func missingBlobsAreReported() async throws {
        await #expect(throws: JMAPError.http(status: 404, problemType: nil)) {
            try await center.previewURL(for: Self.part(blobId: "e3-file9"))
        }
        await #expect(throws: AttachmentDownloadError.notDownloadable(name: "Flight confirmation.pdf")) {
            try await center.data(for: Self.part(blobId: nil))
        }
        #expect(center.downloads.isEmpty)
    }

    // MARK: Saving

    @Test func savingReplacesAFileOnlyWithACompleteCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AttachmentCenterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "Flight confirmation.pdf")
        try Data("the user's own file".utf8).write(to: destination)

        transport.failsDownloads = true
        await #expect(throws: (any Error).self) { try await center.write(Self.part(), to: destination) }
        #expect(try Data(contentsOf: destination) == Data("the user's own file".utf8))

        transport.failsDownloads = false
        try await center.write(Self.part(), to: destination)
        #expect(try Data(contentsOf: destination) == (try await store.cachedAttachment(blobId: "e3-file0")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Flight confirmation.pdf"])
        #expect(root.contents.isEmpty)

        let fresh = folder.appending(path: "Copy.pdf")
        try await center.write(Self.part(), to: fresh)
        #expect(try Data(contentsOf: fresh) == Data(contentsOf: destination))
        #expect(transport.server.downloadCount == 2)
    }

    @Test func savingToAnotherVolumeIsRecognised() {
        // The shape FileManager's replace reports when the two files are on different volumes.
        let crossDevice = CocoaError(.fileWriteUnknown, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)),
            ]),
        ])
        #expect(AttachmentCenter.isCrossDevice(crossDevice))
        #expect(!AttachmentCenter.isCrossDevice(CocoaError(.fileWriteNoPermission)))
    }
}

/// The demo account, whose downloads can stop after their first chunk until released, break off there, or end
/// early without an error.
final class AttachmentCenterTestsTransport: HTTPTransport {
    private struct State {
        var holdsDownloads = false
        var failsDownloads = false
        var truncatesDownloads = false
        var gate = AsyncStream<Void>.makeStream()
    }

    let server = DemoTransport()
    private let state = Mutex(State())

    var holdsDownloads: Bool {
        get { state.withLock { $0.holdsDownloads } }
        set { state.withLock { $0.holdsDownloads = newValue } }
    }

    var failsDownloads: Bool {
        get { state.withLock { $0.failsDownloads } }
        set { state.withLock { $0.failsDownloads = newValue } }
    }

    var truncatesDownloads: Bool {
        get { state.withLock { $0.truncatesDownloads } }
        set { state.withLock { $0.truncatesDownloads = newValue } }
    }

    /// Lets held downloads go on; later ones are held again while `holdsDownloads` is set.
    func releaseDownloads() {
        let gate = state.withLock { state in
            defer { state.gate = AsyncStream<Void>.makeStream() }
            return state.gate
        }
        gate.continuation.finish()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await server.send(request)
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (response, body) = try await server.stream(request)
        let (holds, fails, truncates, gate) = state.withLock {
            ($0.holdsDownloads, $0.failsDownloads, $0.truncatesDownloads, $0.gate.stream)
        }
        guard request.url?.path().contains("/download/") == true, holds || fails || truncates else {
            return (response, body)
        }
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let producer = Task {
            var isFirst = true
            do {
                for try await chunk in body {
                    continuation.yield(chunk)
                    guard isFirst else { continue }
                    isFirst = false
                    if fails { throw URLError(.networkConnectionLost) }
                    if truncates { break }
                    if holds { for await _ in gate {} }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return (response, chunks)
    }
}
