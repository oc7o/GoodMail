import Foundation
import Security

/// Minimal generic-password Keychain wrapper.
///
/// Items are device-only (never synced to iCloud) and readable after first unlock, so background
/// refresh can use them.
///
/// The data protection keychain needs an application identifier, which a macOS build only has when
/// it is signed with a development team. Ad-hoc signed builds (the default for contributors without
/// a team) use the login keychain instead, which is just as local but asks for the login password
/// again whenever the binary changes.
struct Keychain: Sendable {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
            return "Couldn't access the Keychain: \(message) (\(status))"
        }
    }

    let service: String

    func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    func write(_ value: String, for account: String) throws {
        try delete(account)
        var query = baseQuery(account)
        query[kSecValueData] = Data(value.utf8)
        if Self.hasDataProtectionKeychain {
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if Self.hasDataProtectionKeychain {
            query[kSecAttrSynchronizable] = false
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    #if os(macOS)
    /// Probed with a delete because lookups report "not found" rather than the missing entitlement.
    private static let hasDataProtectionKeychain: Bool = {
        let probe: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.goodmail.keychain-probe",
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemDelete(probe as CFDictionary) != errSecMissingEntitlement
    }()
    #else
    private static let hasDataProtectionKeychain = true
    #endif
}
