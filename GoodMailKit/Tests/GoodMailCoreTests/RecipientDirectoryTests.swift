import Foundation
import JMAPKit
import MailCompose
import MailStore
import Synchronization
import Testing
@testable import GoodMailCore

/// Suggestions from a fake address book and correspondents counted from stored mail, all of it as of `now`, so
/// that scores are plain counts.
@MainActor
struct RecipientDirectoryTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_780_000_000)
    static let me = "alex@fastmail.com"

    let store: MailStore
    let contacts = RecipientDirectoryTestsContacts(entries: [
        ContactEntry(name: "Maya Lindqvist", nickname: "May", organization: "Lindqvist Design",
                     emails: ["maya@lindqvist.example", "Maya.L@studio.example"]),
        ContactEntry(name: "Mark Mailer", organization: "Marketing Corp", emails: ["mark@corp.example"]),
        ContactEntry(name: "Shop", emails: ["noreply@shop.example"]),
        ContactEntry(name: "Alex Berg", emails: [RecipientDirectoryTests.me]),
        ContactEntry(name: "Jo Park", organization: "Kiwi Studio", emails: ["jo@park.example"]),
        ContactEntry(name: "Ola Nord", emails: ["ola@nord.example"]),
        ContactEntry(name: "Ola Bye", emails: ["ola@nord.example.com"]),
        ContactEntry(name: "Kari Hansen", emails: ["ola.hansen@kari.example"]),
        ContactEntry(name: "Sven Lund", organization: "Ola Systems", emails: ["sven@lund.example"]),
        ContactEntry(name: "Per Ola", emails: ["per@ola.example"]),
        ContactEntry(name: "Moritz Berg", emails: ["moritz@berg.example"]),
    ])

    init() async throws {
        store = try MailStore(now: { Self.now })
        try await store.replaceMailboxes(Self.mailboxes)
        var emails: [Email] = []
        func receive(_ count: Int, from sender: String, in mailbox: String = "inbox", daysAgo: Double = 0) {
            for _ in 0..<count {
                emails.append(Self.email(in: mailbox, from: sender, to: [Self.me], daysAgo: daysAgo))
            }
        }
        func send(_ count: Int, to recipient: String, daysAgo: Double = 0) {
            for _ in 0..<count {
                emails.append(Self.email(in: "sent", from: "Alex Berg <\(Self.me)>", to: [recipient], daysAgo: daysAgo))
            }
        }
        send(3, to: "Matteo Rossi <matteo@rossi.example>")
        send(1, to: "Maya Lindqvist <maya@lindqvist.example>")
        receive(5, from: "Maya Lindqvist <maya@lindqvist.example>")
        receive(4, from: "Marta <marta@news.example>")
        send(1, to: "Mary Smith <mary@smith.example>")
        receive(5, from: "Shop <noreply@shop.example>")
        send(1, to: "Shopkeeper Sam <sam@shopkeeper.example>")
        receive(3, from: "Max Mustermann <max@spam.example>", in: "junk")
        send(6, to: "Nils Berg <nils@berg.example>", daysAgo: 1)
        send(6, to: "Nina Arnold <nina@arnold.example>")
        send(1, to: "Ola Bye <ola@nord.example.com>")
        send(1, to: "Mona Lisa <mona@lisa.example>", daysAgo: 90)
        try await store.upsert(emails)
    }

    func directory(_ contacts: (any ContactsSource)? = nil) -> RecipientDirectory {
        RecipientDirectory(store: store, contacts: contacts ?? self.contacts)
    }

    func suggest(_ query: String, excluding: Set<String> = [], in directory: RecipientDirectory? = nil) async -> [String] {
        await (directory ?? self.directory())
            .suggestions(for: query, excluding: excluding, isOwn: { $0 == Self.me }).map(\.address.email)
    }

    // MARK: Ranking

    @Test func rankingFollowsMatchSendingAndContacts() async throws {
        // Matteo: name 60 + three sent 60. Maya: name 60 + one sent 20 + five received 10 + contact 15.
        // Mary: name 60 + one sent 20. Mark and Maya's second address: name 60 + contact 15, Mark first by
        // address. Marta only ever wrote, and isn't in Contacts.
        #expect(await suggest("ma") == [
            "matteo@rossi.example", "maya@lindqvist.example", "mary@smith.example", "mark@corp.example",
            "Maya.L@studio.example",
        ])
    }

    @Test func suggestionsSayWhereTheyComeFrom() async throws {
        let suggestions = await directory().suggestions(for: "maya", excluding: [], isOwn: { _ in false })

        #expect(suggestions.map(\.address) == [
            EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example"),
            EmailAddress(name: "Maya Lindqvist", email: "Maya.L@studio.example"),
        ])
        #expect(suggestions.map(\.detail) == ["Lindqvist Design", "Lindqvist Design"])
        #expect(suggestions.map(\.source) == [.both, .contacts])
        #expect(await suggest("matteo", in: directory()).count == 1)
        let matteo = await directory().suggestions(for: "matteo", excluding: [], isOwn: { _ in false })
        #expect(matteo.first?.source == .correspondent)
        #expect(matteo.first?.address.name == "Matteo Rossi")
    }

    @Test func howItMatchesCounts() async throws {
        // All in Contacts. Ola Bye: name 60 + one sent 20; Ola Nord: name 60; Kari: start of the address 50;
        // Sven: organisation 30; Per: elsewhere in the name 10.
        #expect(await suggest("ola") == [
            "ola@nord.example.com", "ola@nord.example", "ola.hansen@kari.example", "sven@lund.example", "per@ola.example",
        ])
        // The exact address 100 beats the start of one 50, even with one sent 20.
        #expect(await suggest("ola@nord.example") == ["ola@nord.example", "ola@nord.example.com"])
        // Nicknames count as names; a second address of the same person matches by name too.
        #expect(await suggest("may") == ["maya@lindqvist.example", "Maya.L@studio.example"])
        #expect(await suggest("kiwi") == ["jo@park.example"])
        #expect(await suggest("park") == ["jo@park.example"])
        #expect(await suggest("zzz") == [])
    }

    @Test func noReplyAddressesSinkBelowPeople() async throws {
        // The shop's name 60 + contact 15 + five received 10 - 50 against Sam's name 60 + one sent 20.
        #expect(await suggest("shop") == ["sam@shopkeeper.example", "noreply@shop.example"])
    }

    @Test func tiesGoToTheMostRecent() async throws {
        // Six sends each count as the five that are the most; Nils's are a day older.
        #expect(await suggest("ni") == ["nina@arnold.example", "nils@berg.example"])
    }

    @Test func beingInContactsCounts() async throws {
        // Moritz: name 60 + contact 15. Mona: name 60 + one sent 90 days ago, which counts half, 10.
        #expect(await suggest("mo") == ["moritz@berg.example", "mona@lisa.example"])
    }

    @Test func ownAndEnteredAddressesAreLeftOut() async throws {
        #expect(await suggest("al") == [])
        #expect(await suggest("ma", excluding: ["MATTEO@rossi.example", "maya.l@studio.example"]) == [
            "maya@lindqvist.example", "mary@smith.example", "mark@corp.example",
        ])
    }

    @Test func peopleYouOnlyHeardFromNeedToBeInContacts() async throws {
        #expect(await suggest("marta") == [])
        #expect(await suggest("max") == [])

        contacts.contactEntries.append(ContactEntry(name: "Marta", emails: ["marta@news.example"]))
        #expect(await suggest("marta") == ["marta@news.example"])
    }

    @Test func atMostTheLimit() async throws {
        let suggestions = await directory().suggestions(for: "m", excluding: [], isOwn: { _ in false }, limit: 2)

        #expect(suggestions.map(\.address.email) == ["matteo@rossi.example", "maya@lindqvist.example"])
        #expect(await directory().suggestions(for: "  ", excluding: [], isOwn: { _ in false }).isEmpty)
    }

    // MARK: The address book

    @Test func anAddressBookChangeIsReadAgain() async throws {
        let directory = directory()
        #expect(await suggest("zoe", in: directory) == [])
        #expect(contacts.reads == 1)

        contacts.change(adding: ContactEntry(name: "Zoë Quinn", emails: ["zoe@quinn.example"]))

        var found: [String] = []
        for _ in 0..<500 where found.isEmpty {
            found = await suggest("zoe", in: directory)
            await Task.yield()
        }
        #expect(found == ["zoe@quinn.example"])
        #expect(contacts.reads == 2)
    }

    @Test func withoutAccessOnlyCorrespondentsYouWroteTo() async throws {
        let denied = RecipientDirectoryTestsContacts(access: .denied, entries: contacts.contactEntries)
        let directory = directory(denied)

        #expect(directory.contactsAccess == .denied)
        #expect(await suggest("ma", in: directory) == ["matteo@rossi.example", "maya@lindqvist.example", "mary@smith.example"])
        #expect(denied.reads == 0)
    }

    @Test func accessIsAskedForOnRequest() async throws {
        let asking = RecipientDirectoryTestsContacts(access: .notDetermined, entries: contacts.contactEntries)
        let directory = directory(asking)
        #expect(directory.contactsAccess == .notDetermined)
        #expect(await suggest("mark", in: directory) == [])

        await directory.requestContactsAccess()

        #expect(asking.requests == 1)
        #expect(directory.contactsAccess == .authorized)
        #expect(await suggest("mark", in: directory) == ["mark@corp.example"])
    }

    @Test func accessTakenAwayInSettingsEmptiesTheAddressBook() async throws {
        let directory = directory()
        #expect(await suggest("mark", in: directory) == ["mark@corp.example"])

        contacts.currentAccess = .denied

        #expect(await suggest("mark", in: directory) == [])
        #expect(directory.contactsAccess == .denied)
    }

    // MARK: Fixtures

    static let mailboxes: [Mailbox] = {
        let json = [("inbox", "inbox"), ("sent", "sent"), ("junk", "junk"), ("trash", "trash")].enumerated()
            .map { index, mailbox -> [String: Any] in
                [
                    "id": mailbox.0, "name": mailbox.0, "role": mailbox.1, "sortOrder": index, "totalEmails": 0,
                    "unreadEmails": 0, "totalThreads": 0, "unreadThreads": 0, "isSubscribed": true,
                ]
            }
        return try! JSONDecoder().decode([Mailbox].self, from: JSONSerialization.data(withJSONObject: json))
    }()

    static func email(in mailbox: String, from sender: String, to recipients: [String], daysAgo: Double) -> Email {
        func address(_ entry: String) -> [String: String] {
            guard let open = entry.firstIndex(of: "<") else { return ["email": entry] }
            return [
                "name": entry[..<open].trimmingCharacters(in: .whitespaces),
                "email": String(entry[entry.index(after: open)...].dropLast()),
            ]
        }
        let id = UUID().uuidString
        let json: [String: Any] = [
            "id": id, "threadId": id, "mailboxIds": [mailbox: true], "keywords": ["$seen": true],
            "receivedAt": now.addingTimeInterval(-daysAgo * 86_400).formatted(.iso8601), "subject": "Hello",
            "from": [address(sender)], "to": recipients.map(address),
        ]
        return try! JMAPCoding.makeDecoder().decode(Email.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

/// An address book in memory, which counts how often it is asked for access and read.
final class RecipientDirectoryTestsContacts: ContactsSource {
    private struct State {
        var access: RecipientDirectory.Access
        var entries: [ContactEntry]
        var reads = 0
        var requests = 0
    }

    private let state: Mutex<State>
    private let changeStream = AsyncStream<Void>.makeStream()

    init(access: RecipientDirectory.Access = .authorized, entries: [ContactEntry]) {
        state = Mutex(State(access: access, entries: entries))
    }

    var currentAccess: RecipientDirectory.Access {
        get { state.withLock { $0.access } }
        set { state.withLock { $0.access = newValue } }
    }

    var contactEntries: [ContactEntry] {
        get { state.withLock { $0.entries } }
        set { state.withLock { $0.entries = newValue } }
    }

    var reads: Int { state.withLock { $0.reads } }
    var requests: Int { state.withLock { $0.requests } }

    func change(adding entry: ContactEntry) {
        state.withLock { $0.entries.append(entry) }
        changeStream.continuation.yield()
    }

    func access() -> RecipientDirectory.Access {
        currentAccess
    }

    func requestAccess() async -> Bool {
        state.withLock { state in
            state.requests += 1
            if state.access == .notDetermined { state.access = .authorized }
            return state.access == .authorized
        }
    }

    func entries() async throws -> [ContactEntry] {
        state.withLock { state in
            state.reads += 1
            return state.entries
        }
    }

    func changes() -> AsyncStream<Void> {
        changeStream.stream
    }
}
