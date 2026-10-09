import Foundation
import GRDB

/// The last unsubscribe request for a mailing list.
public struct Unsubscription: Sendable, Equatable {
    /// The List-Id, else the sender's address. Stored lower-cased.
    public var listKey: String
    /// `oneClick`, `mailto`, `web` or `disableMask`.
    public var method: String
    public var requestedAt: Date
    /// `requested`, `redirected`, `queued` or `failed:<detail>`.
    public var outcome: String

    public init(listKey: String, method: String, requestedAt: Date, outcome: String) {
        self.listKey = listKey
        self.method = method
        self.requestedAt = requestedAt
        self.outcome = outcome
    }
}

extension MailStore {
    /// The last request for the list, matched ignoring case.
    public func unsubscription(listKey: String) async throws -> Unsubscription? {
        try await writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT listKey, method, requestedAt, outcome FROM unsubscription WHERE listKey = ?",
                arguments: [listKey.lowercased()]
            ).map { row in
                Unsubscription(
                    listKey: row["listKey"], method: row["method"],
                    requestedAt: Date(timeIntervalSince1970: row["requestedAt"]), outcome: row["outcome"])
            }
        }
    }

    /// Records a request, replacing the previous one for the same list.
    public func recordUnsubscription(_ unsubscription: Unsubscription) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO unsubscription (listKey, method, requestedAt, outcome) VALUES (?, ?, ?, ?)
                """, arguments: [
                    unsubscription.listKey.lowercased(), unsubscription.method,
                    unsubscription.requestedAt.timeIntervalSince1970, unsubscription.outcome,
                ])
        }
    }
}
