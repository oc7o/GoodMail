import Foundation
import GRDB
import JMAPKit

/// A search the user keeps in the sidebar.
public struct SavedSearch: Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    /// In ``SearchQuery`` syntax.
    public var query: String
    /// The mailbox it searches, or `nil` for all mail but Trash and Spam. An `in:` in the query wins.
    public var mailboxID: String?

    public init(id: String = UUID().uuidString, name: String, query: String, mailboxID: String? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.mailboxID = mailboxID
    }
}

/// The local, encrypted copy of an account's mail: mailboxes, emails, and a full-text index.
///
/// It is a cache. Everything in it can be fetched again, so an unreadable database is simply replaced.
/// Stored emails are kept truthful by applying `Email/changes`; `coverage` records how far back the
/// copy of a mailbox is also complete, so lists never show a recent message while missing a newer one.
///
/// The one exception is the outbox: changes the user made that the server hasn't confirmed yet. They
/// are applied to the stored emails right away and reapplied to every copy fetched until they are sent.
public final class MailStore: Sendable {
    private let writer: any DatabaseWriter

    /// Opens the database at `url`, creating it if needed. `key` supplies 32 random bytes.
    public init(url: URL, key: @escaping @Sendable () throws -> Data) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            let key = try key()
            // A raw key skips SQLCipher's passphrase stretching, which a random key doesn't need.
            try db.usePassphrase("x'" + key.map { String(format: "%02x", $0) }.joined() + "'")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    /// A store that lives only as long as the object, for tests and the demo account.
    public convenience init() throws {
        try self.init(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Removes the database at `url` along with its journal files.
    public static func destroy(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE mailbox (
                    id TEXT PRIMARY KEY,
                    position INTEGER NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE TABLE email (
                    id TEXT PRIMARY KEY,
                    threadId TEXT NOT NULL,
                    receivedAt DOUBLE NOT NULL,
                    isSeen BOOLEAN NOT NULL,
                    json BLOB NOT NULL,
                    body BLOB
                );
                CREATE INDEX email_threadId ON email(threadId);
                CREATE INDEX email_receivedAt ON email(receivedAt);
                CREATE TABLE emailMailbox (
                    mailboxId TEXT NOT NULL,
                    emailId TEXT NOT NULL REFERENCES email(id) ON DELETE CASCADE,
                    PRIMARY KEY (mailboxId, emailId)
                ) WITHOUT ROWID;
                CREATE INDEX emailMailbox_emailId ON emailMailbox(emailId);
                CREATE VIRTUAL TABLE emailText USING fts5(
                    subject, people, body,
                    content = '', contentless_delete = 1, tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TABLE meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("v2") { db in
            // Search operators need the addresses split by header, and flags they can filter on.
            try db.execute(sql: """
                ALTER TABLE email ADD COLUMN isFlagged BOOLEAN NOT NULL DEFAULT 0;
                ALTER TABLE email ADD COLUMN hasAttachment BOOLEAN NOT NULL DEFAULT 0;
                DROP TABLE emailText;
                CREATE VIRTUAL TABLE emailText USING fts5(
                    subject, sender, toRecipients, ccRecipients, bccRecipients, body,
                    content = '', contentless_delete = 1, tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TABLE savedSearch (
                    id TEXT PRIMARY KEY,
                    position INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    query TEXT NOT NULL,
                    mailboxId TEXT
                );
                """)
            let decoder = JMAPCoding.makeDecoder()
            for row in try Row.fetchAll(db, sql: "SELECT rowid, json, body FROM email") {
                let email = try decoder.decode(Email.self, from: row["body"] ?? row["json"])
                try db.execute(
                    sql: "UPDATE email SET isFlagged = ?, hasAttachment = ? WHERE rowid = ?",
                    arguments: [email.has(.flagged), email.hasAttachment ?? false, row["rowid"]])
                try index(email, rowid: row["rowid"], db)
            }
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE pendingChange (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    emailId TEXT NOT NULL,
                    patch BLOB NOT NULL
                );
                CREATE INDEX pendingChange_emailId ON pendingChange(emailId);
                """)
        }
        return migrator
    }

    // MARK: Mailboxes

    public func mailboxes() async throws -> [Mailbox] {
        try await writer.read { db in
            let decoder = JSONDecoder()
            return try Data.fetchAll(db, sql: "SELECT json FROM mailbox ORDER BY position")
                .map { try decoder.decode(Mailbox.self, from: $0) }
        }
    }

    public func replaceMailboxes(_ mailboxes: [Mailbox]) async throws {
        try await writer.write { db in
            let encoder = JSONEncoder()
            try db.execute(sql: "DELETE FROM mailbox")
            for (position, mailbox) in mailboxes.enumerated() {
                try db.execute(
                    sql: "INSERT INTO mailbox (id, position, json) VALUES (?, ?, ?)",
                    arguments: [mailbox.id, position, try encoder.encode(mailbox)])
            }
        }
    }

    // MARK: Emails

    /// Inserts emails or refreshes their keywords and mailboxes. Emails that come with a body keep it
    /// for good, since nothing else about a delivered email ever changes.
    ///
    /// Changes still waiting in the outbox are applied on top, so a copy fetched before the server got
    /// them doesn't undo what the user did.
    public func upsert(_ emails: [Email]) async throws {
        guard !emails.isEmpty else { return }
        try await writer.write { db in
            let encoder = JMAPCoding.makeEncoder()
            let hasPendingChanges = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM pendingChange)")!
            for email in emails {
                guard let threadId = email.threadId, let receivedAt = email.receivedAt else { continue }
                var email = email
                if hasPendingChanges {
                    email = try Self.pendingPatches(for: email.id, db).reduce(email) { $0.applying($1) }
                }
                let isNew = try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM email WHERE id = ?)", arguments: [email.id])!
                try db.execute(sql: """
                    INSERT INTO email (id, threadId, receivedAt, isSeen, isFlagged, hasAttachment, json, body)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        isSeen = excluded.isSeen, isFlagged = excluded.isFlagged, json = excluded.json,
                        body = COALESCE(excluded.body, body)
                    """, arguments: [
                        email.id, threadId, receivedAt.timeIntervalSince1970, email.has(.seen), email.has(.flagged),
                        email.hasAttachment ?? false,
                        try encoder.encode(email.strippingBody()),
                        email.hasBody ? try encoder.encode(email) : nil,
                    ])
                try Self.storeMailboxes(of: email, db)

                if isNew || email.hasBody {
                    let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM email WHERE id = ?", arguments: [email.id])!
                    try Self.index(email, rowid: rowid, db)
                }
            }
        }
    }

    private static func storeMailboxes(of email: Email, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM emailMailbox WHERE emailId = ?", arguments: [email.id])
        for mailboxId in (email.mailboxIds ?? [:]).keys {
            try db.execute(sql: "INSERT INTO emailMailbox (mailboxId, emailId) VALUES (?, ?)", arguments: [mailboxId, email.id])
        }
    }

    private static func index(_ email: Email, rowid: Int64, _ db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO emailText (rowid, subject, sender, toRecipients, ccRecipients, bccRecipients, body)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                rowid, email.subject, SearchText.addresses(email.from), SearchText.addresses(email.to),
                SearchText.addresses(email.cc), SearchText.addresses(email.bcc), SearchText.body(of: email),
            ])
    }

    public func deleteEmails(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            for id in ids {
                try db.execute(
                    sql: "DELETE FROM emailText WHERE rowid = (SELECT rowid FROM email WHERE id = ?)", arguments: [id])
                try db.execute(sql: "DELETE FROM email WHERE id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM pendingChange WHERE emailId = ?", arguments: [id])
            }
        }
    }

    /// The stored emails with these ids, without bodies.
    public func emails(ids: [String]) async throws -> [Email] {
        try await writer.read { db in
            let decoder = JMAPCoding.makeDecoder()
            return try ids.compactMap { id in
                try Data.fetchOne(db, sql: "SELECT json FROM email WHERE id = ?", arguments: [id])
                    .map { try decoder.decode(Email.self, from: $0) }
            }
        }
    }

    /// Every email of a thread with its body, oldest first, or `nil` if any body is still missing.
    public func emailsWithBodies(inThread threadId: String) async throws -> [Email]? {
        try await writer.read { db in
            let decoder = JMAPCoding.makeDecoder()
            let rows = try Row.fetchAll(
                db, sql: "SELECT json, body FROM email WHERE threadId = ? ORDER BY receivedAt, id", arguments: [threadId])
            guard !rows.isEmpty else { return nil }
            var emails: [Email] = []
            for row in rows {
                guard let body: Data = row["body"] else { return nil }
                let current = try decoder.decode(Email.self, from: row["json"])
                emails.append(try decoder.decode(Email.self, from: body).withFlags(of: current))
            }
            return emails
        }
    }

    /// Ids of the newest emails whose body hasn't been stored yet, looking at the `window` newest emails.
    public func emailIDsMissingBody(amongNewest window: Int, limit: Int) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM (SELECT id, body, receivedAt FROM email ORDER BY receivedAt DESC LIMIT ?)
                WHERE body IS NULL ORDER BY receivedAt DESC LIMIT ?
                """, arguments: [window, limit])
        }
    }

    /// Forgets all emails and sync progress, keeping mailboxes and the outbox. Used when the server can
    /// no longer tell what changed since our last sync.
    public func resetEmails() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM emailText; DELETE FROM email; DELETE FROM meta")
        }
    }

    // MARK: Thread lists

    public struct ThreadQuery: Sendable, Hashable {
        /// Only emails in this mailbox; `nil` searches everywhere.
        public var mailboxID: String?
        /// Emails that are in none but these mailboxes don't count, e.g. Trash and Spam.
        public var hiddenMailboxIDs: [String]
        /// Its `mailbox` is ignored; pass the resolved mailbox as `mailboxID` instead.
        public var search: SearchQuery
        public var unreadOnly: Bool
        /// Ignore emails received before this date.
        public var since: Date?

        public init(
            mailboxID: String? = nil, hiddenMailboxIDs: [String] = [], search: SearchQuery = .init(),
            unreadOnly: Bool = false, since: Date? = nil
        ) {
            self.mailboxID = mailboxID
            self.hiddenMailboxIDs = hiddenMailboxIDs
            self.search = search
            self.unreadOnly = unreadOnly
            self.since = since
        }
    }

    /// Conversations with at least one email matching `query`, newest first.
    public func threads(matching query: ThreadQuery, limit: Int) async throws -> [ThreadSummary] {
        try await writer.read { db in
            guard let (conditions, arguments) = Self.conditions(for: query, db) else { return [] }
            // With MAX(), SQLite takes the other columns from the row holding the maximum.
            let anchors = try Row.fetchAll(db, sql: """
                SELECT e.threadId, e.id, MAX(e.receivedAt) AS newest FROM email e
                WHERE \(conditions) GROUP BY e.threadId ORDER BY newest DESC, e.threadId LIMIT ?
                """, arguments: arguments + [limit])
            return try Self.summaries(db, anchors: anchors.map { ($0["threadId"], $0["id"]) })
        }
    }

    public func threadCount(matching query: ThreadQuery) async throws -> Int {
        try await writer.read { db in
            guard let (conditions, arguments) = Self.conditions(for: query, db) else { return 0 }
            return try Int.fetchOne(
                db, sql: "SELECT COUNT(DISTINCT e.threadId) FROM email e WHERE \(conditions)", arguments: arguments) ?? 0
        }
    }

    /// The given conversations as far as they are stored, in no particular order. Each is anchored at
    /// its newest email.
    public func threads(ids: [String]) async throws -> [ThreadSummary] {
        try await writer.read { db in
            let anchors = try ids.compactMap { threadId -> (String, String)? in
                try String.fetchOne(
                    db, sql: "SELECT id FROM email WHERE threadId = ? ORDER BY receivedAt DESC, id LIMIT 1",
                    arguments: [threadId]
                ).map { (threadId, $0) }
            }
            return try Self.summaries(db, anchors: anchors)
        }
    }

    private static func conditions(for query: ThreadQuery, _ db: Database) -> (String, StatementArguments)? {
        var conditions = ["1"]
        var arguments = StatementArguments()
        if let mailboxID = query.mailboxID {
            conditions.append("EXISTS (SELECT 1 FROM emailMailbox m WHERE m.emailId = e.id AND m.mailboxId = ?)")
            arguments += [mailboxID]
        }
        if !query.hiddenMailboxIDs.isEmpty {
            let placeholders = databaseQuestionMarks(count: query.hiddenMailboxIDs.count)
            conditions.append(
                "EXISTS (SELECT 1 FROM emailMailbox m WHERE m.emailId = e.id AND m.mailboxId NOT IN (\(placeholders)))")
            arguments += StatementArguments(query.hiddenMailboxIDs)
        }
        let search = query.search
        if !search.terms.isEmpty {
            guard let pattern = matchPattern(for: search.terms) else { return nil }
            conditions.append("e.rowid IN (SELECT rowid FROM emailText WHERE emailText MATCH ?)")
            arguments += [pattern]
        }
        if query.unreadOnly || search.isUnread == true {
            conditions.append("NOT e.isSeen")
        } else if search.isUnread == false {
            conditions.append("e.isSeen")
        }
        if let isFlagged = search.isFlagged {
            conditions.append(isFlagged ? "e.isFlagged" : "NOT e.isFlagged")
        }
        if let hasAttachment = search.hasAttachment {
            conditions.append(hasAttachment ? "e.hasAttachment" : "NOT e.hasAttachment")
        }
        if let since = [query.since, search.after].compactMap({ $0 }).max() {
            conditions.append("e.receivedAt >= ?")
            arguments += [since.timeIntervalSince1970]
        }
        if let before = search.before {
            conditions.append("e.receivedAt < ?")
            arguments += [before.timeIntervalSince1970]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }

    /// An FTS5 query requiring every term, each limited to its column, or `nil` if a term has nothing
    /// to search for.
    private static func matchPattern(for terms: [SearchQuery.Term]) -> String? {
        var parts: [String] = []
        for term in terms {
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: term.value) else { return nil }
            let column: String? = switch term.field {
            case .text: nil
            case .from: "sender"
            case .to: "toRecipients"
            case .cc: "ccRecipients"
            case .bcc: "bccRecipients"
            case .subject: "subject"
            case .body: "body"
            }
            parts.append(column.map { "\($0) : (\(pattern.rawPattern))" } ?? "(\(pattern.rawPattern))")
        }
        return parts.joined(separator: " AND ")
    }

    private static func summaries(_ db: Database, anchors: [(threadId: String, anchorId: String)]) throws -> [ThreadSummary] {
        let decoder = JMAPCoding.makeDecoder()
        return try anchors.map { anchor in
            let emails = try Data.fetchAll(
                db, sql: "SELECT json FROM email WHERE threadId = ? ORDER BY receivedAt, id", arguments: [anchor.threadId]
            ).map { try decoder.decode(Email.self, from: $0) }
            return ThreadSummary(id: anchor.threadId, emails: emails, anchorId: anchor.anchorId)
        }
    }

    // MARK: Saved searches

    public func savedSearches() async throws -> [SavedSearch] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, query, mailboxId FROM savedSearch ORDER BY position").map {
                SavedSearch(id: $0["id"], name: $0["name"], query: $0["query"], mailboxID: $0["mailboxId"])
            }
        }
    }

    /// Adds a saved search at the end, or updates it where it is.
    public func save(_ search: SavedSearch) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO savedSearch (id, position, name, query, mailboxId)
                VALUES (?, (SELECT COALESCE(MAX(position), -1) + 1 FROM savedSearch), ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET name = excluded.name, query = excluded.query, mailboxId = excluded.mailboxId
                """, arguments: [search.id, search.name, search.query, search.mailboxID])
        }
    }

    public func deleteSavedSearch(id: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM savedSearch WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Outbox

    /// Changes to send to the server in one `Email/set`.
    public struct PendingChanges: Sendable, Equatable {
        /// The last queued change included; pass it to ``removePendingChanges(through:)`` once sent.
        public let throughSeq: Int64
        /// Each email's queued patches merged into one.
        public let updates: [String: PatchObject]
    }

    /// Applies patches to the stored emails and queues them for the server. Emails that aren't stored
    /// are queued all the same.
    public func enqueue(_ updates: [String: PatchObject]) async throws {
        guard !updates.isEmpty else { return }
        try await writer.write { db in
            let decoder = JMAPCoding.makeDecoder(), encoder = JMAPCoding.makeEncoder()
            for (id, patch) in updates.sorted(by: { $0.key < $1.key }) {
                if let json = try Data.fetchOne(db, sql: "SELECT json FROM email WHERE id = ?", arguments: [id]) {
                    let email = try decoder.decode(Email.self, from: json).applying(patch)
                    try db.execute(
                        sql: "UPDATE email SET isSeen = ?, isFlagged = ?, json = ? WHERE id = ?",
                        arguments: [email.has(.seen), email.has(.flagged), try encoder.encode(email), id])
                    try Self.storeMailboxes(of: email, db)
                }
                try db.execute(
                    sql: "INSERT INTO pendingChange (emailId, patch) VALUES (?, ?)",
                    arguments: [id, try Self.patchEncoder.encode(patch)])
            }
        }
    }

    /// The oldest queued changes, merged per email, or `nil` if nothing is queued.
    ///
    /// Takes changes in order and stops before the first one for an email beyond `limit`, so a later
    /// change is never sent ahead of an earlier one.
    public func pendingChanges(limit: Int = 200) async throws -> PendingChanges? {
        precondition(limit > 0)
        return try await writer.read { db in
            var updates: [String: PatchObject] = [:]
            var throughSeq: Int64?
            let rows = try Row.fetchCursor(db, sql: "SELECT seq, emailId, patch FROM pendingChange ORDER BY seq")
            while let row = try rows.next() {
                let id: String = row["emailId"]
                if updates[id] == nil, updates.count == limit { break }
                let patch = try JSONDecoder().decode(PatchObject.self, from: row["patch"])
                updates[id] = updates[id].map { $0.merging(patch) } ?? patch
                throughSeq = row["seq"]
            }
            return throughSeq.map { PendingChanges(throughSeq: $0, updates: updates) }
        }
    }

    /// Drops queued changes up to and including `seq`; with `emailIDs`, only those to these emails.
    public func removePendingChanges(through seq: Int64, emailIDs: Set<String>? = nil) async throws {
        try await writer.write { db in
            guard let emailIDs else {
                return try db.execute(sql: "DELETE FROM pendingChange WHERE seq <= ?", arguments: [seq])
            }
            for id in emailIDs {
                try db.execute(sql: "DELETE FROM pendingChange WHERE seq <= ? AND emailId = ?", arguments: [seq, id])
            }
        }
    }

    /// How many emails have changes waiting.
    public func pendingEmailCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT emailId) FROM pendingChange") ?? 0
        }
    }

    private static let patchEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func pendingPatches(for emailId: String, _ db: Database) throws -> [PatchObject] {
        try Data.fetchAll(db, sql: "SELECT patch FROM pendingChange WHERE emailId = ? ORDER BY seq", arguments: [emailId])
            .map { try JSONDecoder().decode(PatchObject.self, from: $0) }
    }

    // MARK: Sync progress

    /// The JMAP `Email` state the stored emails are in sync with.
    public func emailState() async throws -> String? {
        try await value(for: "emailState")
    }

    public func setEmailState(_ state: String) async throws {
        try await setValue(state, for: "emailState")
    }

    /// The date from which the copy of a mailbox is complete: every email in it received on or after
    /// that date is stored. `nil` if nothing is known to be complete yet.
    ///
    /// Combines what was learned from paging through that mailbox with the account-wide backfill.
    public func coverage(mailboxID: String) async throws -> Date? {
        let dates = try await [value(for: "coverage:\(mailboxID)"), value(for: "coverage")]
            .compactMap { $0.flatMap(Double.init) }
        return dates.min().map(Date.init(timeIntervalSince1970:))
    }

    /// Records that everything received on or after `date` is stored, for one mailbox or (with `nil`)
    /// for the whole account. Coverage only ever grows.
    public func extendCoverage(mailboxID: String?, to date: Date) async throws {
        let key = mailboxID.map { "coverage:\($0)" } ?? "coverage"
        try await writer.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
                .flatMap(Double.init)
            let value = min(existing ?? .infinity, date.timeIntervalSince1970)
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, String(value)])
        }
    }

    /// Where the account-wide backfill stands: the receive date of the oldest email it has reached.
    public func backfillCursor() async throws -> Date? {
        try await value(for: "coverage").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    private func value(for key: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    private func setValue(_ value: String, for key: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }
}
