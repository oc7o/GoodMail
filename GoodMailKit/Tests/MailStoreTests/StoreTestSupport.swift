import Foundation
import GRDB
import JMAPKit
import Synchronization
@testable import MailStore

/// A clock the test moves by hand. It starts at a whole second, so that dates survive the store's
/// seconds-since-1970 columns exactly.
final class StoreTestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date = StoreFixtures.epoch) {
        self.date = Mutex(date)
    }

    var now: Date { date.withLock { $0 } }

    func advance(days: Double) {
        date.withLock { $0.addTimeInterval(days * 86_400) }
    }

    func advance(seconds: TimeInterval) {
        date.withLock { $0.addTimeInterval(seconds) }
    }

    /// For `MailStore(now:)`.
    var reading: @Sendable () -> Date { { self.now } }
}

/// A folder for a store's files that the test deletes when it ends.
struct StoreFolder {
    let url = FileManager.default.temporaryDirectory.appending(path: "MailStoreTests-\(UUID().uuidString)")
    var storeURL: URL { url.appending(path: "Mail.sqlite") }
    var blobURL: URL { url.appending(path: "Mail-blobs.sqlite") }
    var unreadable: URL { url.appending(path: "Unreadable") }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: name).path)
    }

    /// Folders in `Unreadable/`, each with the names of its files.
    func unreadableSets() throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: unreadable.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: unreadable.path).sorted().map { set in
            try FileManager.default.contentsOfDirectory(atPath: unreadable.appending(path: set).path).sorted()
        }
    }
}

enum StoreFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func randomKey() -> Data {
        randomData(32)
    }

    static func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return data
    }

    static func mailboxes(_ roles: [String: String?]) -> [Mailbox] {
        let json = roles.sorted { $0.key < $1.key }.enumerated().map { index, entry in
            var mailbox: [String: Any] = [
                "id": entry.key, "name": entry.key, "sortOrder": index, "totalEmails": 0, "unreadEmails": 0,
                "totalThreads": 0, "unreadThreads": 0, "isSubscribed": true,
            ]
            if let role = entry.value { mailbox["role"] = role }
            return mailbox
        }
        return try! JSONDecoder().decode([Mailbox].self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The usual set: Inbox, Sent, Junk, Trash and a folder without a role.
    static let standardMailboxes = mailboxes(
        ["inbox": "inbox", "sent": "sent", "junk": "junk", "trash": "trash", "projects": nil])

    struct File {
        var blobId: String
        var name: String? = nil
        var type: String = "application/pdf"
        var size: Int? = 1000
        var inline = false
    }

    /// An email received `day` days after ``epoch``; with `files` or `body: true` it comes with its body.
    static func email(
        _ id: String, thread: String? = nil, in mailboxes: [String] = ["inbox"], day: Double = 0,
        keywords: [String] = [], from: [String] = ["Maya Lindqvist <maya@example.com>"], to: [String] = [],
        cc: [String] = [], bcc: [String] = [], files: [File] = [], body: Bool = false
    ) -> Email {
        func addresses(_ list: [String]) -> [[String: String]] {
            list.map { entry in
                guard let open = entry.firstIndex(of: "<") else { return ["email": entry] }
                return [
                    "name": entry[..<open].trimmingCharacters(in: .whitespaces),
                    "email": String(entry[entry.index(after: open)...].dropLast()),
                ]
            }
        }
        var json: [String: Any] = [
            "id": id, "threadId": thread ?? id,
            "receivedAt": epoch.addingTimeInterval(day * 86_400).formatted(.iso8601),
            "mailboxIds": Dictionary(uniqueKeysWithValues: mailboxes.map { ($0, true) }),
            "keywords": Dictionary(uniqueKeysWithValues: keywords.map { ($0, true) }),
            "subject": "Subject of \(id)", "preview": "", "hasAttachment": !files.isEmpty,
            "from": addresses(from), "to": addresses(to), "cc": addresses(cc), "bcc": addresses(bcc),
        ]
        if body || !files.isEmpty {
            json["htmlBody"] = [["partId": "1", "type": "text/html"]]
            json["bodyValues"] = ["1": ["value": "<p>Hello</p>", "isEncodingProblem": false, "isTruncated": false]]
            json["attachments"] = files.map { file in
                var part: [String: Any] = [
                    "blobId": file.blobId, "type": file.type, "disposition": file.inline ? "inline" : "attachment",
                ]
                if let name = file.name { part["name"] = name }
                if let size = file.size { part["size"] = size }
                if file.inline { part["cid"] = "\(file.blobId)@example" }
                return part
            }
        }
        return try! JMAPCoding.makeDecoder().decode(Email.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

extension MailStore {
    /// Chunk sizes of the blob at `key`, in order.
    func chunkSizes(of key: String) async throws -> [Int] {
        try await blobs.writer.read { db in
            try Int.fetchAll(db, sql: "SELECT length(data) FROM chunk WHERE key = ? ORDER BY seq", arguments: [key])
        }
    }

    /// Rows in the blob file's tables, complete or not.
    func blobRowCounts() async throws -> (blobs: Int, chunks: Int) {
        try await blobs.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blob")!, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk")!)
        }
    }

    /// Runs maintenance until nothing is waiting, and returns how many slices that took.
    @discardableResult
    func maintainFully(slice: Int = MailStore.backfillSlice) async throws -> Int {
        var slices = 1
        while try await performMaintenance(slice: slice) { slices += 1 }
        return slices
    }

    func correspondent(_ address: String) async throws -> Correspondent? {
        try await correspondents(matching: address, limit: 50).first { $0.address == address }
    }
}
