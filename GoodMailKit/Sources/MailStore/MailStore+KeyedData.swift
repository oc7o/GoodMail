import Foundation
import GRDB

/// Small values that belong to the account rather than to its mail, such as what is known about the
/// account for starting offline. Unlike sync progress, they survive ``MailStore/resetEmails()``.
///
/// Keys starting with `MailStore.` are the store's own.
extension MailStore {
    public func keyedData(_ key: String) async throws -> Data? {
        try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM keyedData WHERE key = ?", arguments: [key])
        }
    }

    /// Stores `data` under `key`; `nil` removes the key.
    public func setKeyedData(_ data: Data?, for key: String) async throws {
        try await writer.write { db in
            if let data {
                // Empty Data binds as NULL.
                try db.execute(
                    sql: "INSERT OR REPLACE INTO keyedData (key, value) VALUES (?, COALESCE(?, X''))",
                    arguments: [key, data])
            } else {
                try db.execute(sql: "DELETE FROM keyedData WHERE key = ?", arguments: [key])
            }
        }
    }
}
