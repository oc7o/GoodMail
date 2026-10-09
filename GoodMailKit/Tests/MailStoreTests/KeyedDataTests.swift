import Foundation
import Testing
@testable import MailStore

/// Unsubscribe requests and keyed data: small records that outlive a reset of the stored mail.
struct KeyedDataTests {
    let store = try! MailStore()

    @Test func unsubscriptionsAreKeptPerListIgnoringCase() async throws {
        try await store.recordUnsubscription(Unsubscription(
            listKey: "<News.Example.com>", method: "mailto", requestedAt: StoreFixtures.epoch, outcome: "queued"))

        #expect(try await store.unsubscription(listKey: "<news.example.COM>") == Unsubscription(
            listKey: "<news.example.com>", method: "mailto", requestedAt: StoreFixtures.epoch, outcome: "queued"))

        let retried = Unsubscription(
            listKey: "<news.example.com>", method: "oneClick", requestedAt: StoreFixtures.epoch.addingTimeInterval(60),
            outcome: "failed:HTTP 404")
        try await store.recordUnsubscription(retried)
        #expect(try await store.unsubscription(listKey: "<NEWS.example.com>") == retried)
        #expect(try await store.unsubscription(listKey: "shop@example.com") == nil)
    }

    @Test func keyedDataSurvivesAResetOfTheEmails() async throws {
        let snapshot = Data(#"{"username":"alex@example.com"}"#.utf8)
        try await store.setKeyedData(snapshot, for: "account")
        try await store.setKeyedData(Data(), for: "empty")
        try await store.recordUnsubscription(Unsubscription(
            listKey: "list", method: "web", requestedAt: StoreFixtures.epoch, outcome: "requested"))
        try await store.upsert([StoreFixtures.email("e1")])
        _ = try await store.performMaintenance()
        #expect(try await store.keyedData(MailStore.backfillBoundaryKey) != nil)

        try await store.resetEmails()

        #expect(try await store.keyedData("account") == snapshot)
        #expect(try await store.keyedData("empty") == Data())
        #expect(try await store.keyedData("missing") == nil)
        #expect(try await store.unsubscription(listKey: "list") != nil)
        // The store's own bookkeeping starts over with the emails.
        #expect(try await store.keyedData(MailStore.backfillBoundaryKey) == nil)

        try await store.setKeyedData(nil, for: "account")
        #expect(try await store.keyedData("account") == nil)
    }
}
