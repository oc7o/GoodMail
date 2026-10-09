import Contacts
import Foundation

/// A person or organisation from the address book, as far as recipient suggestions need it.
public struct ContactEntry: Sendable, Hashable {
    /// The full name, or the organisation for a company card.
    public var name: String
    public var nickname: String?
    public var organization: String?
    public var emails: [String]

    public init(name: String, nickname: String? = nil, organization: String? = nil, emails: [String]) {
        self.name = name
        self.nickname = nickname
        self.organization = organization
        self.emails = emails
    }
}

/// Where recipient suggestions get the address book from.
public protocol ContactsSource: Sendable {
    func access() -> RecipientDirectory.Access
    /// Asks the user (only the first time); true when access was granted.
    func requestAccess() async -> Bool
    /// Every contact with an email address.
    func entries() async throws -> [ContactEntry]
    /// An element whenever the address book changes.
    func changes() -> AsyncStream<Void>
}

/// The system address book (`CNContactStore`). Contacts are read into memory only: never written to disk, logged
/// or sent anywhere.
public struct SystemContacts: ContactsSource {
    public init() {}

    public func access() -> RecipientDirectory.Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        #if os(iOS)
        case .limited: .limited
        #endif
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Enumerating blocks until done, so it runs on a dispatch queue rather than on a thread of the concurrency
    /// pool.
    public func entries() async throws -> [ContactEntry] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.readEntries() })
            }
        }
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // The notification comes only while a store is around to receive it.
            let observation = ContactStoreObservation(onChange: { continuation.yield() })
            continuation.onTermination = { _ in observation.end() }
        }
    }

    private static func readEntries() throws -> [ContactEntry] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var entries: [ContactEntry] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            let emails = contact.emailAddresses.map { $0.value as String }.filter { !$0.isEmpty }
            guard !emails.isEmpty else { return }
            let organization = contact.organizationName.isEmpty ? nil : contact.organizationName
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? organization ?? ""
            entries.append(ContactEntry(
                name: name, nickname: contact.nickname.isEmpty ? nil : contact.nickname, organization: organization,
                emails: emails))
        }
        return entries
    }
}

/// Keeps a contact store and a notification observer alive for as long as an address-book change stream runs.
/// Unchecked: after `init`, only `end()` touches it, and NotificationCenter allows that from any thread.
private final class ContactStoreObservation: @unchecked Sendable {
    private let store = CNContactStore()
    private let observer: any NSObjectProtocol

    init(onChange: @escaping @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil) { _ in onChange() }
    }

    func end() {
        NotificationCenter.default.removeObserver(observer)
    }
}
