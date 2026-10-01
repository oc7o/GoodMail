import Foundation
import GRDB
import JMAPKit

/// The local, encrypted copy of an account's mail: mailboxes, emails, and a full-text index.
///
/// It is a cache. Everything in it can be fetched again, so an unreadable database is simply replaced.
/// Stored emails are kept truthful by applying `Email/changes`; `coverage` records how far back the
/// copy of a mailbox is also complete, so lists never show a recent message while missing a newer one.
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
    public init() throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    /// Removes the database at `url` along with its journal files.
    public static func destroy(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private static var migrator: DatabaseMigrator {
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
    public func upsert(_ emails: [Email]) async throws {
        guard !emails.isEmpty else { return }
        try await writer.write { db in
            let encoder = JMAPCoding.makeEncoder()
            for email in emails {
                guard let threadId = email.threadId, let receivedAt = email.receivedAt else { continue }
                let isNew = try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM email WHERE id = ?)", arguments: [email.id])!
                try db.execute(sql: """
                    INSERT INTO email (id, threadId, receivedAt, isSeen, json, body) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        isSeen = excluded.isSeen, json = excluded.json, body = COALESCE(excluded.body, body)
                    """, arguments: [
                        email.id, threadId, receivedAt.timeIntervalSince1970, email.has(.seen),
                        try encoder.encode(email.strippingBody()),
                        email.hasBody ? try encoder.encode(email) : nil,
                    ])

                try db.execute(sql: "DELETE FROM emailMailbox WHERE emailId = ?", arguments: [email.id])
                for mailboxId in (email.mailboxIds ?? [:]).keys {
                    try db.execute(
                        sql: "INSERT INTO emailMailbox (mailboxId, emailId) VALUES (?, ?)",
                        arguments: [mailboxId, email.id])
                }

                if isNew || email.hasBody {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO emailText (rowid, subject, people, body)
                        SELECT rowid, ?, ?, ? FROM email WHERE id = ?
                        """, arguments: [email.subject, SearchText.people(of: email), SearchText.body(of: email), email.id])
                }
            }
        }
    }

    public func deleteEmails(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            for id in ids {
                try db.execute(
                    sql: "DELETE FROM emailText WHERE rowid = (SELECT rowid FROM email WHERE id = ?)", arguments: [id])
                try db.execute(sql: "DELETE FROM email WHERE id = ?", arguments: [id])
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

    /// Forgets all emails and sync progress, keeping mailboxes. Used when the server can no longer
    /// tell what changed since our last sync.
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
        public var search: String
        public var unreadOnly: Bool
        /// Ignore emails received before this date.
        public var since: Date?

        public init(
            mailboxID: String? = nil, hiddenMailboxIDs: [String] = [], search: String = "",
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
        if !query.search.isEmpty {
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query.search) else { return nil }
            conditions.append("e.rowid IN (SELECT rowid FROM emailText WHERE emailText MATCH ?)")
            arguments += [pattern]
        }
        if query.unreadOnly {
            conditions.append("NOT e.isSeen")
        }
        if let since = query.since {
            conditions.append("e.receivedAt >= ?")
            arguments += [since.timeIntervalSince1970]
        }
        return (conditions.joined(separator: " AND "), arguments)
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
