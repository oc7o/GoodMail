import Foundation
import MailPrivacy
import Synchronization

/// The only place decrypted attachment files are made: copies for Quick Look, sharing and saving, each in a folder
/// of its own, deleted as soon as they aren't needed. They live under `root`, except copies that are to replace a
/// saved file, which have to be on that file's volume (`copy(named:toReplace:write:)`).
///
/// On iOS copies can only be read while the device is unlocked (complete protection); on macOS they are
/// quarantined like other mail attachments. They are deleted when released (after `releaseDelay`), and all at
/// once on sign-out, when the token is rejected, when the app quits or goes to the background, and at launch
/// (`purgeContainerTemporaryDirectory()`).
public actor TemporaryFiles {
    /// `tmp/Attachments`. On macOS a released copy stays 10 minutes, so that an app opened from Quick Look still
    /// finds it; on iOS nothing outside the app can still be reading it.
    public static let shared = TemporaryFiles(
        root: FileManager.default.temporaryDirectory.appending(path: "Attachments", directoryHint: .isDirectory),
        releaseDelay: platformReleaseDelay)

    #if os(macOS)
    static let platformReleaseDelay = Duration.seconds(600)
    #else
    static let platformReleaseDelay = Duration.zero
    #endif

    public let root: URL
    private let releaseDelay: Duration
    /// Released copies waiting for their delay, by folder.
    private var releases: [URL: Task<Void, Never>] = [:]
    /// The folders of copies that are to replace a saved file. `purgeAllNow()` needs them without waiting for the
    /// actor.
    private nonisolated let replacements = Mutex<Set<URL>>([])

    public init(root: URL, releaseDelay: Duration) {
        self.root = root
        self.releaseDelay = releaseDelay
    }

    /// Makes a new file named `name`, made safe by `SafeFilename`, and has `write` fill it. If `write` fails, the
    /// file is gone again.
    public func copy(named name: String, write: @Sendable (FileHandle) async throws -> Void) async throws -> URL {
        try await fill(root.appending(path: UUID().uuidString, directoryHint: .isDirectory), named: name, write: write)
    }

    /// Makes a new file like `copy(named:write:)`, to take the place of `destination` through `replace(_:with:)`.
    ///
    /// One file can replace another in one step only within a volume, so the copy goes into a new folder that the
    /// system keeps for files being saved on the destination's volume. `purgeAllNow()` deletes it too. One that a
    /// crash leaves on another volume than the app's stays there: the purge at launch can't reach it.
    func copy(
        named name: String, toReplace destination: URL, write: @Sendable (FileHandle) async throws -> Void
    ) async throws -> URL {
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
        ).standardizedFileURL
        replacements.withLock { _ = $0.insert(folder) }
        return try await fill(folder, named: name, write: write)
    }

    /// Puts `copy`, made by `copy(named:toReplace:write:)`, in the place of `destination` in one step, so that a file
    /// already there stays whole if that fails. The copy is gone afterwards either way.
    func replace(_ destination: URL, with copy: URL) throws {
        let folder = copy.deletingLastPathComponent().standardizedFileURL
        defer {
            if replacements.withLock({ $0.remove(folder) }) != nil { Self.remove(folder) }
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: copy)
    }

    /// The folders of the copies that are to replace a file, made and not yet gone.
    nonisolated var replacementFolders: Set<URL> {
        replacements.withLock { $0 }
    }

    /// Makes `name`, made safe by `SafeFilename`, in `folder`, and has `write` fill it. If that fails, the folder is
    /// gone again.
    private func fill(
        _ folder: URL, named name: String, write: @Sendable (FileHandle) async throws -> Void
    ) async throws -> URL {
        let file = folder.appending(path: SafeFilename.make(name, mimeType: nil), directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #if os(iOS)
            let attributes: [FileAttributeKey: Any]? = [.protectionKey: FileProtectionType.complete]
            #else
            let attributes: [FileAttributeKey: Any]? = nil
            #endif
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: attributes)
            else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
            let handle = try FileHandle(forWritingTo: file)
            do {
                try await write(handle)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            #if os(macOS)
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "GoodMail",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
            ]
            var quarantined = file
            try quarantined.setResourceValues(values)
            #endif
            return file
        } catch {
            replacements.withLock { _ = $0.remove(folder) }
            Self.remove(folder)
            throw error
        }
    }

    /// The copy at `url` is no longer needed: it is deleted after the release delay. URLs that aren't copies of
    /// this instance are ignored.
    public func release(_ url: URL) {
        guard let folder = folder(of: url), releases[folder] == nil else { return }
        guard releaseDelay > .zero else {
            Self.remove(folder)
            return
        }
        let delay = releaseDelay
        releases[folder] = Task {
            // A cancelled wait means the copy is purged right away instead.
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self.finishRelease(of: folder)
        }
    }

    /// Deletes every released copy now, without waiting for its delay: for iOS, when the app goes to the
    /// background. Copies still shown stay.
    public func purgeReleased() {
        for (folder, wait) in releases {
            wait.cancel()
            Self.remove(folder)
        }
        releases = [:]
    }

    /// Deletes every copy at once, released or not, including those about to replace a saved file: when the macOS
    /// app quits, on sign-out, and when the token is rejected. Synchronous, so it can run while the app terminates.
    public nonisolated func purgeAllNow() {
        Self.removeContents(of: root)
        for folder in replacements.withLock({ folders in defer { folders = [] }; return folders }) {
            Self.remove(folder)
        }
    }

    /// Empties the app's own temporary directory, at launch, before anything uses it: decrypted copies that a
    /// crash or a kill left behind, and the files of system components such as the share sheet and file
    /// exporters (C32). Outside an app container (`swift test`, a command-line tool), the temporary directory is
    /// shared with other processes, so nothing happens there.
    public nonisolated static func purgeContainerTemporaryDirectory() {
        guard let directory = containerTemporaryDirectory(
            home: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
            temporary: FileManager.default.temporaryDirectory)
        else { return }
        removeContents(of: directory)
    }

    /// The temporary directory when it is an app container's own: `tmp` inside the home directory, which a
    /// sandbox makes the container (`~/Library/Containers/<id>/Data` on macOS, `…/Containers/Data/Application/<id>`
    /// on iOS).
    nonisolated static func containerTemporaryDirectory(home: URL, temporary: URL) -> URL? {
        // iOS names the same folder /var/mobile/… and /private/var/mobile/… (a symbolic link).
        func components(_ url: URL) -> [String] {
            let components = url.standardizedFileURL.pathComponents
            return components.count > 2 && components[1] == "private" ? [components[0]] + components[2...] : components
        }
        let home = components(home)
        guard home.contains("Containers"), home.count > 3, components(temporary) == home + ["tmp"] else {
            return nil
        }
        return temporary
    }

    // MARK: Bookkeeping

    private func finishRelease(of folder: URL) {
        guard releases.removeValue(forKey: folder) != nil else { return }
        Self.remove(folder)
    }

    /// The folder of a copy: a direct subfolder of `root`.
    private func folder(of url: URL) -> URL? {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().pathComponents == root.standardizedFileURL.pathComponents else {
            return nil
        }
        return folder
    }

    private static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    private nonisolated static func removeContents(of directory: URL) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in contents { try? fileManager.removeItem(at: item) }
    }
}
