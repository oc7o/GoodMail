import Foundation
import JMAPKit
import MailCompose
import MailStore
import Observation

/// Recipient suggestions (§2.7, D28): the address book, which stays in memory only, together with the people the
/// account wrote to or heard from (`MailStore.correspondents(matching:limit:)`).
///
/// Suggestions rank by how well they match, then by how much mail went to them, so someone you write to comes
/// first. People you have only heard from appear only if they are in the address book, so a newsletter or a
/// stranger never turns up as a recipient.
@MainActor
@Observable
public final class RecipientDirectory {
    public enum Access: Sendable, Equatable {
        case notDetermined
        /// iOS: the user picked which contacts GoodMail sees.
        case limited
        case authorized
        case denied
    }

    public private(set) var contactsAccess: Access
    private let store: MailStore
    private let contacts: any ContactsSource
    /// The address book, read on first use and again after each change.
    @ObservationIgnored private var book: AddressBook?
    /// Counts address-book changes, so that a read that started before the last one is read again.
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?

    public init(store: MailStore, contacts: any ContactsSource = SystemContacts()) {
        self.store = store
        self.contacts = contacts
        contactsAccess = contacts.access()
    }

    isolated deinit {
        watching?.cancel()
    }

    /// Asks for the address book; the system asks the user only the first time.
    public func requestContactsAccess() async {
        _ = await contacts.requestAccess()
        contactsAccess = contacts.access()
        changeCount += 1
        await loadContacts()
    }

    /// Up to `limit` people to send to, best first, for what was typed so far.
    ///
    /// - Parameters:
    ///   - excluding: Addresses already entered.
    ///   - isOwn: The user's own addresses (identities, masked addresses, the login), which are never suggested.
    public func suggestions(
        for query: String, excluding: Set<String>, isOwn: (String) -> Bool, limit: Int = 8
    ) async -> [AddressSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let book = await addressBook()
        // Every match: the store orders them by weights of its own, so a list cut short there could end before
        // the people who rank first here, behind senders who are left out below.
        let correspondents = (try? await store.correspondents(matching: query, limit: .max)) ?? []
        let search = Search(query)

        var candidates: [String: Candidate] = [:]
        for person in book.people {
            guard let quality = search.quality(of: person.searchable) else { continue }
            if let known = candidates[person.address], known.quality >= quality { continue }
            candidates[person.address] = Candidate(person, quality: quality)
        }
        for correspondent in correspondents {
            let contact = book.byAddress[correspondent.address]
            // Someone you only heard from needs to be in Contacts, whichever name their mail carries.
            guard correspondent.lastSent != nil || contact != nil else { continue }
            let searchable = Searchable(address: correspondent.address, name: correspondent.name)
            let quality = search.quality(of: searchable) ?? Search.anywhere
            var candidate = candidates[correspondent.address]
                ?? contact.map { Candidate($0, quality: quality) }
                ?? Candidate(correspondent, quality: quality)
            candidate.quality = max(candidate.quality, quality)
            candidate.correspondent = correspondent
            candidates[correspondent.address] = candidate
        }

        let excluded = Set(excluding.map { $0.lowercased() })
        return candidates.values
            .filter { !excluded.contains($0.key) && !isOwn($0.key) }
            .map { (candidate: $0, rank: $0.rank) }
            .sorted { $0.rank.isAbove($1.rank) }
            .prefix(limit)
            .map(\.candidate.suggestion)
    }

    // MARK: Address book

    private var hasAccess: Bool {
        contactsAccess == .authorized || contactsAccess == .limited
    }

    /// The address book as last read; read now if it never was. Empty without access, which the user can
    /// change in Settings at any time.
    private func addressBook() async -> AddressBook {
        let access = contacts.access()
        if access != contactsAccess {
            contactsAccess = access
            changeCount += 1
            book = nil
        }
        guard hasAccess else { return AddressBook() }
        if book == nil || loading != nil { await loadContacts() }
        return book ?? AddressBook()
    }

    /// Reads the address book until no change came in during the read, and watches it from then on.
    private func loadContacts() async {
        if let loading { return await loading.value }
        let task = Task {
            var changes: Int
            repeat {
                changes = changeCount
                book = AddressBook(hasAccess ? ((try? await contacts.entries()) ?? []) : [])
            } while changes != changeCount
        }
        loading = task
        await task.value
        loading = nil
        if hasAccess { watchChanges() }
    }

    private func watchChanges() {
        guard watching == nil else { return }
        let changes = contacts.changes()
        watching = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                contactsAccess = contacts.access()
                changeCount += 1
                await loadContacts()
            }
        }
    }
}

// MARK: Ranking

extension RecipientDirectory {
    /// What a match is worth (§2.7): the best way it matches, how often you wrote to them and heard from them,
    /// whether they are in the address book; less for addresses nobody reads.
    private struct Candidate {
        var address: EmailAddress
        var detail: String?
        var quality: Int
        var isInContacts: Bool
        var correspondent: Correspondent?

        /// Someone in Contacts goes by the card's name, whichever name matched.
        init(_ person: Person, quality: Int) {
            address = EmailAddress(name: person.name.isEmpty ? nil : person.name, email: person.email)
            detail = person.organization
            self.quality = quality
            isInContacts = true
        }

        init(_ correspondent: Correspondent, quality: Int) {
            address = EmailAddress(name: correspondent.name, email: correspondent.address)
            self.quality = quality
            isInContacts = false
            self.correspondent = correspondent
        }

        var key: String { address.email.lowercased() }

        var score: Double {
            var score = Double(quality)
            if let correspondent {
                score += min(correspondent.sentScore, 5) * 20 + min(correspondent.receivedScore, 5) * 2
            }
            if isInContacts { score += 15 }
            if Self.isNoReply(key) { score -= 50 }
            return score
        }

        var lastContact: Date {
            [correspondent?.lastSent, correspondent?.lastReceived].compactMap { $0 }.max() ?? .distantPast
        }

        /// What the order goes by, worked out once for each candidate rather than at every comparison.
        var rank: Rank { Rank(score: score, lastContact: lastContact, key: key) }

        struct Rank {
            let score: Double
            let lastContact: Date
            let key: String

            /// The higher score first; ties go to the most recent, then by address.
            func isAbove(_ other: Rank) -> Bool {
                if score != other.score { return score > other.score }
                if lastContact != other.lastContact { return lastContact > other.lastContact }
                return key < other.key
            }
        }

        var suggestion: AddressSuggestion {
            let source: AddressSuggestion.Source = switch (isInContacts, correspondent != nil) {
            case (true, true): .both
            case (true, false): .contacts
            case (false, _): .correspondent
            }
            return AddressSuggestion(address: address, detail: detail, source: source)
        }

        /// Addresses that don't take replies: "noreply", "no-reply", "do_not_reply", "mailer-daemon", bounce addresses.
        static func isNoReply(_ address: String) -> Bool {
            let local = address.split(separator: "@").first.map { $0.filter { $0.isLetter || $0.isNumber } } ?? ""
            return local.hasPrefix("noreply") || local.hasPrefix("donotreply")
                || ["mailerdaemon", "bounce", "bounces"].contains(local)
        }
    }

    /// Every address of every card, also by lower-cased address, which is what tells whether someone is in
    /// Contacts.
    private struct AddressBook {
        var people: [Person] = []
        var byAddress: [String: Person] = [:]

        init() {}

        init(_ entries: [ContactEntry]) {
            people = entries.flatMap(Person.all)
            byAddress = Dictionary(people.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// One address of a contact, with what is searched folded once instead of at every keystroke.
    private struct Person {
        let email: String
        let address: String
        let name: String
        let organization: String?
        let searchable: Searchable

        static func all(of entry: ContactEntry) -> [Person] {
            entry.emails.map { email in
                let address = email.trimmingCharacters(in: .whitespaces).lowercased()
                return Person(
                    email: email.trimmingCharacters(in: .whitespaces), address: address, name: entry.name,
                    organization: entry.organization,
                    searchable: Searchable(
                        address: address, name: entry.name, nickname: entry.nickname, organization: entry.organization))
            }
        }
    }

    /// The folded text a query is matched against.
    private struct Searchable {
        let address: String
        let nameWords: [String]
        let nicknameWords: [String]
        let organizationWords: [String]
        let text: String

        init(address: String, name: String?, nickname: String? = nil, organization: String? = nil) {
            self.address = Search.folded(address)
            nameWords = Search.words(of: Search.folded(name ?? ""))
            nicknameWords = Search.words(of: Search.folded(nickname ?? ""))
            organizationWords = Search.words(of: Search.folded(organization ?? ""))
            text = Search.folded([name, nickname, organization, address].compactMap { $0 }.joined(separator: " "))
        }
    }

    /// A query, matched ignoring case, diacritics and width, the way `MailStore` finds correspondents.
    private struct Search {
        static let exactAddress = 100
        static let firstNameWord = 60
        static let addressStart = 50
        static let organization = 30
        static let anywhere = 10

        let text: String
        let words: [String]

        init(_ query: String) {
            text = Self.folded(query)
            words = Self.words(of: text)
        }

        /// The best of: the exact address; the name or nickname from its first word on; the start of the address; a
        /// word of the organisation; anywhere else. `nil` if it doesn't match at all.
        func quality(of searchable: Searchable) -> Int? {
            if searchable.address == text { return Self.exactAddress }
            if matchesWords(searchable.nameWords, from: 0) || matchesWords(searchable.nicknameWords, from: 0) {
                return Self.firstNameWord
            }
            if searchable.address.hasPrefix(text) { return Self.addressStart }
            if matchesWords(searchable.organizationWords) { return Self.organization }
            if matchesWords(searchable.nameWords) || matchesWords(searchable.nicknameWords)
                || searchable.text.contains(text)
            {
                return Self.anywhere
            }
            return nil
        }

        /// Whether the query's words match consecutive words, whole except for the last, which may be a prefix.
        private func matchesWords(_ candidate: [String], from start: Int? = nil) -> Bool {
            guard let last = words.last, words.count <= candidate.count else { return false }
            let starts = start.map { [$0] } ?? Array(0...(candidate.count - words.count))
            return starts.contains { start in
                start + words.count <= candidate.count
                    && zip(candidate[start...], words.dropLast()).allSatisfy { $0 == $1 }
                    && candidate[start + words.count - 1].hasPrefix(last)
            }
        }

        static func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }

        static func words(of text: String) -> [String] {
            text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
    }
}
