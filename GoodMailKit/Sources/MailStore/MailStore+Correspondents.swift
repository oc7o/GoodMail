import Foundation
import GRDB
import JMAPKit

/// Someone the account has written to or heard from, for recipient suggestions.
public struct Correspondent: Sendable, Hashable {
    /// Lower-cased.
    public let address: String
    public let name: String?
    /// Emails sent to them and received from them, each counting less the older it is: half after 90 days.
    public let sentScore: Double
    public let receivedScore: Double
    public let lastSent: Date?
    public let lastReceived: Date?

    public init(
        address: String, name: String?, sentScore: Double, receivedScore: Double, lastSent: Date?, lastReceived: Date?
    ) {
        self.address = address
        self.name = name
        self.sentScore = sentScore
        self.receivedScore = receivedScore
        self.lastSent = lastSent
        self.lastReceived = lastReceived
    }
}

/// Correspondents are counted from stored mail only: by `upsert`, once for each email new to the store, and
/// by maintenance for mail stored before they existed. Sending counts when the Sent copy arrives, so a message
/// is never counted twice.
///
/// A score is kept as of its latest email (`sentAt`, `receivedAt`) and decayed to the present when read.
extension MailStore {
    enum Direction {
        case sent, received
    }

    static let correspondentHalfLife: TimeInterval = 90 * 86_400

    /// Correspondents whose address starts with `text`, or whose name has a word starting with it (several
    /// words: consecutive words), ignoring case and diacritics. Best first: someone you write to weighs ten
    /// times as much as someone you hear from.
    public func correspondents(matching text: String, limit: Int) async throws -> [Correspondent] {
        let query = Self.folded(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let queryWords = Self.words(of: query)
        guard !query.isEmpty, limit > 0 else { return [] }
        let now = self.now().timeIntervalSince1970
        let matches = try await writer.read { db in
            // A cheap filter first. LIKE ignores case only in ASCII, so names and addresses with other
            // characters always pass it; the exact match follows in Swift.
            var conditions = ["address LIKE ? ESCAPE '\\'", "address GLOB '*[^ -~]*'"]
            var arguments: StatementArguments = [Self.escapedForLike(query) + "%"]
            if let first = queryWords.first {
                conditions += ["name LIKE ? ESCAPE '\\'", "name GLOB '*[^ -~]*'"]
                arguments += ["%" + Self.escapedForLike(String(first)) + "%"]
            }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT address, name, sentScore, sentAt, receivedScore, receivedAt FROM correspondent
                WHERE \(conditions.joined(separator: " OR "))
                """, arguments: arguments)
            var matches: [Correspondent] = []
            while let row = try rows.next() {
                let address: String = row["address"], name: String? = row["name"]
                guard Self.folded(address).hasPrefix(query)
                    || name.map({ Self.hasWordPrefix(Self.words(of: Self.folded($0)), queryWords) }) == true
                else { continue }
                let sentAt: Double? = row["sentAt"], receivedAt: Double? = row["receivedAt"]
                matches.append(Correspondent(
                    address: address, name: name,
                    sentScore: Self.decayed(row["sentScore"], since: sentAt, now: now),
                    receivedScore: Self.decayed(row["receivedScore"], since: receivedAt, now: now),
                    lastSent: sentAt.map(Date.init(timeIntervalSince1970:)),
                    lastReceived: receivedAt.map(Date.init(timeIntervalSince1970:))))
            }
            return matches
        }
        return Array(matches.sorted(by: Self.ranksHigher).prefix(limit))
    }

    // MARK: Counting

    /// Counts the people of a newly stored email: whom it went to if it is in Sent, else who it came
    /// from, unless it is only in Junk or Trash. Drafts don't count.
    static func countCorrespondents(of email: Email, roles: [String: Mailbox.Role], _ db: Database) throws {
        guard !email.has(.draft), let receivedAt = email.receivedAt else { return }
        let mailboxRoles = (email.mailboxIds ?? [:]).filter(\.value).keys.map { roles[$0] }
        let people: [EmailAddress], direction: Direction
        if mailboxRoles.contains(.sent) {
            people = (email.to ?? []) + (email.cc ?? []) + (email.bcc ?? [])
            direction = .sent
        } else if mailboxRoles.contains(where: { $0 != .junk && $0 != .trash }) {
            people = email.from ?? []
            direction = .received
        } else {
            return
        }
        var counted = Set<String>()
        for person in people {
            let address = person.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard address.contains("@"), counted.insert(address).inserted else { continue }
            try count(address, name: person.name, direction, at: receivedAt.timeIntervalSince1970, db)
        }
    }

    private static func count(
        _ address: String, name: String?, _ direction: Direction, at time: Double, _ db: Database
    ) throws {
        var sent: (score: Double, at: Double?) = (0, nil), received: (score: Double, at: Double?) = (0, nil)
        var storedName: String?
        if let row = try Row.fetchOne(
            db, sql: "SELECT name, sentScore, sentAt, receivedScore, receivedAt FROM correspondent WHERE address = ?",
            arguments: [address])
        {
            sent = (row["sentScore"], row["sentAt"])
            received = (row["receivedScore"], row["receivedAt"])
            storedName = row["name"]
        }
        let latest = [sent.at, received.at].compactMap { $0 }.max()
        switch direction {
        case .sent: sent = adding(time, to: sent)
        case .received: received = adding(time, to: received)
        }
        // The newest name wins; one from an older email only fills a gap.
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty, storedName == nil || latest.map({ time >= $0 }) ?? true {
            storedName = name
        }
        try db.execute(sql: """
            INSERT INTO correspondent (address, name, sentScore, sentAt, receivedScore, receivedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (address) DO UPDATE SET
                name = excluded.name, sentScore = excluded.sentScore, sentAt = excluded.sentAt,
                receivedScore = excluded.receivedScore, receivedAt = excluded.receivedAt
            """, arguments: [address, storedName, sent.score, sent.at, received.score, received.at])
    }

    /// One more email at `time`, which may be older than the latest one counted: mail isn't stored in
    /// date order.
    static func adding(_ time: Double, to score: (score: Double, at: Double?)) -> (score: Double, at: Double?) {
        guard let at = score.at else { return (1, time) }
        let reference = max(at, time)
        return (score.score * decay(reference - at) + decay(reference - time), reference)
    }

    static func decayed(_ score: Double, since time: Double?, now: Double) -> Double {
        guard let time else { return score }
        return score * decay(now - time)
    }

    private static func decay(_ interval: TimeInterval) -> Double {
        exp2(-max(0, interval) / correspondentHalfLife)
    }

    private static func ranksHigher(_ a: Correspondent, _ b: Correspondent) -> Bool {
        let weightA = a.sentScore * 10 + a.receivedScore, weightB = b.sentScore * 10 + b.receivedScore
        if weightA != weightB { return weightA > weightB }
        let latestA = [a.lastSent, a.lastReceived].compactMap { $0 }.max() ?? .distantPast
        let latestB = [b.lastSent, b.lastReceived].compactMap { $0 }.max() ?? .distantPast
        if latestA != latestB { return latestA > latestB }
        return a.address < b.address
    }

    // MARK: Matching

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func words(of text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// Whether `query` matches `words` from some word on: whole words, the last one as a prefix.
    private static func hasWordPrefix(_ words: [Substring], _ query: [Substring]) -> Bool {
        guard let last = query.last, query.count <= words.count else { return false }
        return (0...(words.count - query.count)).contains { start in
            zip(words[start...], query.dropLast()).allSatisfy { $0 == $1 }
                && words[start + query.count - 1].hasPrefix(last)
        }
    }

    private static func escapedForLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
