import Foundation
import JMAPKit
import Testing
@testable import MailStore

/// Whom the account writes to and hears from, counted from stored mail for recipient suggestions.
struct CorrespondentTests {
    let clock = StoreTestClock()
    let store: MailStore

    init() throws {
        store = try MailStore(now: clock.reading)
    }

    private func storeMail(_ emails: [Email]) async throws {
        try await store.replaceMailboxes(StoreFixtures.standardMailboxes)
        try await store.upsert(emails)
    }

    private func scores(_ address: String) async throws -> (sent: Double, received: Double)? {
        try await store.correspondent(address).map { ($0.sentScore, $0.receivedScore) }
    }

    private func search(_ text: String, limit: Int = 10) async throws -> [String] {
        try await store.correspondents(matching: text, limit: limit).map(\.address)
    }

    @Test func sentMailCountsItsRecipientsAndOtherMailItsSender() async throws {
        try await storeMail([
            StoreFixtures.email(
                "s1", in: ["sent"], from: ["Me <me@example.com>"], to: ["Maya <maya@example.com>"],
                cc: ["jonas@example.com", "maya@example.com"], bcc: ["Nora <NORA@Example.com>"]),
            StoreFixtures.email("r1", from: ["Olaf <olaf@example.com>"], to: ["me@example.com"]),
            StoreFixtures.email("r2", in: ["projects"], from: ["pia@example.com"]),
            StoreFixtures.email("r3", in: ["inbox", "trash"], from: ["kai@example.com"]),
            StoreFixtures.email("d1", in: ["sent"], keywords: ["$draft"], to: ["quinn@example.com"]),
            StoreFixtures.email("d2", keywords: ["$draft"], from: ["rita@example.com"]),
            StoreFixtures.email("j1", in: ["junk"], from: ["spam@example.com"]),
            StoreFixtures.email("t1", in: ["trash"], from: ["gone@example.com"]),
            StoreFixtures.email("t2", in: ["junk", "trash"], from: ["both@example.com"]),
        ])

        for address in ["maya@example.com", "jonas@example.com", "nora@example.com"] {
            #expect(try await scores(address)! == (1, 0), "\(address)")
        }
        for address in ["olaf@example.com", "pia@example.com", "kai@example.com"] {
            #expect(try await scores(address)! == (0, 1), "\(address)")
        }
        for address in [
            "me@example.com", "quinn@example.com", "rita@example.com", "spam@example.com", "gone@example.com",
            "both@example.com",
        ] {
            #expect(try await scores(address) == nil, "\(address)")
        }
        #expect(try await store.correspondent("maya@example.com")?.name == "Maya")
    }

    @Test func eachEmailCountsOnce() async throws {
        let email = StoreFixtures.email("r1", from: ["maya@example.com"])
        try await storeMail([email])

        try await store.upsert([email])
        try await store.upsert([StoreFixtures.email("r1", keywords: ["$seen", "$flagged"], from: ["maya@example.com"])])
        try await store.upsert([StoreFixtures.email("r1", from: ["maya@example.com"], body: true)])
        try await store.enqueue(["r1": .move(from: "inbox", to: "projects")])
        try await store.upsert([email])

        #expect(try await scores("maya@example.com")! == (0, 1))

        try await store.upsert([StoreFixtures.email("r2", from: ["maya@example.com"])])
        #expect(try await scores("maya@example.com")! == (0, 2))
    }

    @Test func scoresHalveEveryNinetyDays() async throws {
        try await storeMail([
            StoreFixtures.email("r1", day: 0, from: ["maya@example.com"]),
            StoreFixtures.email("r2", day: 90, from: ["maya@example.com"]),
        ])
        clock.advance(days: 90)
        #expect(try await scores("maya@example.com")! == (0, 1.5))

        clock.advance(days: 90)
        #expect(try await scores("maya@example.com")! == (0, 0.75))

        // An older email stored late counts as old as it is.
        try await store.upsert([StoreFixtures.email("r0", day: -90, from: ["maya@example.com"])])
        #expect(try await scores("maya@example.com")! == (0, 0.875))
        let maya = try #require(try await store.correspondent("maya@example.com"))
        #expect(maya.lastReceived == StoreFixtures.epoch.addingTimeInterval(90 * 86_400))
        #expect(maya.lastSent == nil)
    }

    @Test func theNewestNameWins() async throws {
        try await storeMail([StoreFixtures.email("r1", day: 2, from: ["Maya L <maya@example.com>"])])
        try await store.upsert([StoreFixtures.email("r2", day: 1, from: ["Maya Old <maya@example.com>"])])
        #expect(try await store.correspondent("maya@example.com")?.name == "Maya L")

        try await store.upsert([StoreFixtures.email("r3", day: 3, from: ["maya@example.com"])])
        #expect(try await store.correspondent("maya@example.com")?.name == "Maya L")

        try await store.upsert([StoreFixtures.email("r4", day: 4, from: ["Maya Lindqvist <maya@example.com>"])])
        #expect(try await store.correspondent("maya@example.com")?.name == "Maya Lindqvist")

        // An older email still fills in a name nobody gave yet.
        try await store.upsert([StoreFixtures.email("r5", day: 5, from: ["nora@example.com"])])
        try await store.upsert([StoreFixtures.email("r6", day: 1, from: ["Nora Nilsson <nora@example.com>"])])
        #expect(try await store.correspondent("nora@example.com")?.name == "Nora Nilsson")
    }

    @Test func searchMatchesTheStartOfTheAddressOrOfNameWords() async throws {
        try await storeMail([
            StoreFixtures.email("r1", from: ["Maya Lindqvist <maya.l@example.com>"]),
            StoreFixtures.email("r2", from: ["Jürgen Weiß <jw@example.de>"]),
            StoreFixtures.email("r3", from: ["Anna-Lena O'Brien <al@example.ie>"]),
            StoreFixtures.email("r4", from: ["100%_sure <percent@example.com>"]),
            StoreFixtures.email("r5", from: ["amaya@example.com"]),
        ])

        #expect(try await search("may") == ["maya.l@example.com"])
        #expect(try await search("MAYA.L@") == ["maya.l@example.com"])
        #expect(try await search("lind") == ["maya.l@example.com"])
        #expect(try await search("Maya Lin") == ["maya.l@example.com"])
        #expect(try await search("lindqvist maya").isEmpty)
        #expect(try await search("aya").isEmpty)
        #expect(try await search("jur") == ["jw@example.de"])
        #expect(try await search("weiss") == ["jw@example.de"])
        #expect(try await search("WEIß") == ["jw@example.de"])
        #expect(try await search("lena") == ["al@example.ie"])
        #expect(try await search("o'brien") == ["al@example.ie"])
        #expect(try await search("100%") == ["percent@example.com"])
        #expect(try await search("%").isEmpty)
        #expect(try await search("_").isEmpty)
        #expect(try await search("  ").isEmpty)
        #expect(try await search("a", limit: 0).isEmpty)
    }

    @Test func peopleYouWriteToComeFirst() async throws {
        try await storeMail([
            StoreFixtures.email("r1", day: 0, from: ["sam.a@example.com"]),
            StoreFixtures.email("r2", day: 0, from: ["sam.a@example.com"]),
            StoreFixtures.email("r3", day: 0, from: ["sam.a@example.com"]),
            StoreFixtures.email("s1", in: ["sent"], day: 0, to: ["sam.b@example.com"]),
            StoreFixtures.email("r4", day: 1, from: ["sam.c@example.com"]),
            StoreFixtures.email("r5", day: 2, from: ["sam.d@example.com"]),
        ])

        #expect(try await search("sam") == ["sam.b@example.com", "sam.a@example.com", "sam.d@example.com", "sam.c@example.com"])
        #expect(try await search("sam", limit: 2) == ["sam.b@example.com", "sam.a@example.com"])
    }

    @Test func resetForgetsCorrespondentsUntilTheMailIsStoredAgain() async throws {
        let email = StoreFixtures.email("r1", from: ["maya@example.com"])
        try await storeMail([email])

        try await store.resetEmails()
        #expect(try await scores("maya@example.com") == nil)

        try await store.upsert([email])
        #expect(try await scores("maya@example.com")! == (0, 1))
        try await store.maintainFully()
        #expect(try await scores("maya@example.com")! == (0, 1))
    }
}
