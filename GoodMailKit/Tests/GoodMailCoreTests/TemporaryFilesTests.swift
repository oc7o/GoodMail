import Foundation
import Synchronization
import Testing
@testable import GoodMailCore

/// Decrypted copies: where they go, and that every way of getting rid of them does.
struct TemporaryFilesTests {
    /// A root of its own for every test, deleted when the test ends.
    final class Root {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TemporaryFilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)

        deinit { try? FileManager.default.removeItem(at: url) }

        func files(releaseDelay: Duration = .zero) -> TemporaryFiles {
            TemporaryFiles(root: url, releaseDelay: releaseDelay)
        }

        var contents: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        }
    }

    /// Folders noted while a test runs, such as those of copies that are only there for a moment.
    final class SeenFolders: Sendable {
        private let seen = Mutex<Set<URL>>([])

        var folders: Set<URL> { seen.withLock { $0 } }

        func add(_ folders: Set<URL>) {
            seen.withLock { $0.formUnion(folders) }
        }
    }

    let root = Root()

    static func write(_ text: String) -> @Sendable (FileHandle) async throws -> Void {
        { handle in try handle.write(contentsOf: Data(text.utf8)) }
    }

    @Test func copiesGetAFolderEachAndASafeName() async throws {
        let files = root.files()

        let first = try await files.copy(named: "../Invoice\u{202E}fdp.exe", write: Self.write("one"))
        let second = try await files.copy(named: "../Invoice\u{202E}fdp.exe", write: Self.write("two"))

        #expect(first.lastPathComponent == "Invoicefdp.exe")
        #expect(first.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == root.url.standardizedFileURL)
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
    }

    #if os(macOS)
    @Test func copiesAreQuarantinedLikeMailAttachments() async throws {
        let copy = try await root.files().copy(named: "Invoice.pdf", write: Self.write("%PDF"))

        let quarantine = try #require(try copy.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(quarantine[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeEmailAttachment as String)
        #expect(getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }
    #endif

    @Test func aFailedWriteLeavesNothing() async throws {
        struct Failure: Error {}
        let files = root.files()

        await #expect(throws: Failure.self) {
            try await files.copy(named: "Half.pdf") { handle in
                try handle.write(contentsOf: Data("half".utf8))
                throw Failure()
            }
        }
        #expect(root.contents.isEmpty)
    }

    @Test func releaseDeletesTheCopy() async throws {
        let files = root.files()
        let kept = try await files.copy(named: "Kept.pdf", write: Self.write("kept"))
        let released = try await files.copy(named: "Released.pdf", write: Self.write("released"))

        await files.release(released)

        #expect(!FileManager.default.fileExists(atPath: released.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(root.contents == [kept.deletingLastPathComponent().lastPathComponent])
    }

    @Test func releaseIgnoresFilesOfOthers() async throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "TemporaryFilesTests-\(UUID().uuidString).txt")
        try Data("not ours".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let files = root.files()
        let copy = try await files.copy(named: "Kept.pdf", write: Self.write("kept"))

        await files.release(outside)
        await files.release(root.url)
        await files.release(root.url.appending(path: "Kept.pdf"))

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func aDelayedReleaseWaitsUnlessPurged() async throws {
        let files = root.files(releaseDelay: .seconds(3600))
        let released = try await files.copy(named: "Released.pdf", write: Self.write("released"))
        let shown = try await files.copy(named: "Shown.pdf", write: Self.write("shown"))

        await files.release(released)
        #expect(FileManager.default.fileExists(atPath: released.path))

        await files.purgeReleased()
        #expect(!FileManager.default.fileExists(atPath: released.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: shown.path))
    }

    @Test func purgeAllNowEmptiesTheRoot() async throws {
        let files = root.files(releaseDelay: .seconds(3600))
        let released = try await files.copy(named: "Released.pdf", write: Self.write("released"))
        _ = try await files.copy(named: "Shown.pdf", write: Self.write("shown"))
        await files.release(released)

        files.purgeAllNow()

        #expect(root.contents.isEmpty)
        // Copies made afterwards still work.
        let next = try await files.copy(named: "Next.pdf", write: Self.write("next"))
        #expect(FileManager.default.fileExists(atPath: next.path))
    }

    // MARK: Copies that replace a saved file

    /// A file of the user's, outside every root, for a copy to replace.
    final class Destination {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TemporaryFilesTests-\(UUID().uuidString).pdf", directoryHint: .notDirectory)

        init() throws { try Data("old".utf8).write(to: url) }

        deinit { try? FileManager.default.removeItem(at: url) }

        var text: String? { try? String(contentsOf: url, encoding: .utf8) }
    }

    @Test func aCopyThatReplacesAFileIsMadeBesideTheRootAndGoneOnceItDid() async throws {
        let files = root.files()
        let destination = try Destination()

        let copy = try await files.copy(named: "../Invoice.pdf", toReplace: destination.url, write: Self.write("new"))

        #expect(copy.lastPathComponent == "Invoice.pdf")
        #expect(files.replacementFolders == [copy.deletingLastPathComponent().standardizedFileURL])
        #expect(root.contents.isEmpty)
        #expect(destination.text == "old")
        #if os(macOS)
        #expect(getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        #endif

        try await files.replace(destination.url, with: copy)

        #expect(destination.text == "new")
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(files.replacementFolders.isEmpty)
    }

    @Test func aCopyThatCantReplaceItsFileIsGoneAllTheSame() async throws {
        let files = root.files()
        let destination = try Destination()
        let copy = try await files.copy(named: "Invoice.pdf", toReplace: destination.url, write: Self.write("new"))
        try FileManager.default.removeItem(at: copy)

        await #expect(throws: (any Error).self) { try await files.replace(destination.url, with: copy) }

        #expect(destination.text == "old")
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(files.replacementFolders.isEmpty)
    }

    @Test func aFailedCopyToReplaceAFileLeavesNothing() async throws {
        struct Failure: Error {}
        let files = root.files()
        let destination = try Destination()
        let seen = SeenFolders()

        await #expect(throws: Failure.self) {
            try await files.copy(named: "Half.pdf", toReplace: destination.url) { handle in
                try handle.write(contentsOf: Data("half".utf8))
                seen.add(files.replacementFolders)
                throw Failure()
            }
        }

        #expect(seen.folders.count == 1)
        #expect(seen.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(files.replacementFolders.isEmpty)
        #expect(destination.text == "old")
    }

    @Test func purgeAllNowAlsoDeletesCopiesAboutToReplaceAFile() async throws {
        let files = root.files()
        let destination = try Destination()
        let copy = try await files.copy(named: "Invoice.pdf", toReplace: destination.url, write: Self.write("new"))

        files.purgeAllNow()

        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(files.replacementFolders.isEmpty)
        // A save under way when that happens fails without touching the file.
        await #expect(throws: (any Error).self) { try await files.replace(destination.url, with: copy) }
        #expect(destination.text == "old")
    }

    @Test func purgingTheContainerTemporaryDirectoryDoesNothingOutsideAContainer() throws {
        let canary = FileManager.default.temporaryDirectory.appending(path: "TemporaryFilesTests-canary-\(UUID().uuidString)")
        try Data("still here".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: canary) }

        TemporaryFiles.purgeContainerTemporaryDirectory()

        #expect(FileManager.default.fileExists(atPath: canary.path))
    }

    @Test(arguments: [
        // Sandboxed macOS app, iOS app (with the /var symlink), iOS simulator.
        ("/Users/alex/Library/Containers/dev.goodmail.GoodMail/Data",
         "/Users/alex/Library/Containers/dev.goodmail.GoodMail/Data/tmp/", true),
        ("/var/mobile/Containers/Data/Application/0C3A1E52-4D2B-4F0E-9A51-2B7C1C0C5E11",
         "/private/var/mobile/Containers/Data/Application/0C3A1E52-4D2B-4F0E-9A51-2B7C1C0C5E11/tmp/", true),
        ("/Users/alex/Library/Developer/CoreSimulator/Devices/9F1C/data/Containers/Data/Application/77AB",
         "/Users/alex/Library/Developer/CoreSimulator/Devices/9F1C/data/Containers/Data/Application/77AB/tmp", true),
        // Command-line tools and tests, and anything that isn't the container's own tmp.
        ("/Users/alex", "/var/folders/xy/abc123/T/", false),
        ("/Users/alex/Library/Containers/dev.goodmail.GoodMail/Data", "/var/folders/xy/abc123/T/", false),
        ("/Users/alex/Library/Containers/dev.goodmail.GoodMail/Data",
         "/Users/alex/Library/Containers/dev.goodmail.GoodMail/Data/Library/Caches", false),
        ("/Users/alex", "/Users/alex/tmp", false),
        ("/Containers", "/Containers/tmp", false),
    ])
    func onlyAContainersOwnTemporaryDirectoryIsPurged(home: String, temporary: String, isContainer: Bool) {
        let directory = TemporaryFiles.containerTemporaryDirectory(
            home: URL(filePath: home, directoryHint: .isDirectory),
            temporary: URL(filePath: temporary, directoryHint: .isDirectory))

        #expect((directory != nil) == isContainer)
    }
}
