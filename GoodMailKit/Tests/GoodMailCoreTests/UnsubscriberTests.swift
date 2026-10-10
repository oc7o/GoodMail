import DemoAccount
import Foundation
import JMAPKit
import MailCompose
import MailPrivacy
import MailStore
import Synchronization
import Testing
@testable import GoodMailCore

/// Unsubscribing from the demo account's newsletter (e4), which has Fastmail's header layout and arrived at the
/// masked address fjord.k3x9@fastmail.com. One-click requests go to a recording transport, never the network.
@MainActor
struct UnsubscriberTests {
    let server = DemoTransport()
    let client: JMAPClient
    let store: MailStore
    let oneClick = UnsubscriberTestsTransport()
    let resolver = UnsubscriberTestsResolver()

    static let oneClickURL = DemoTransport.oneClickUnsubscribeURL
    static let mailto = ListUnsubscribe.Method.mailto(MailtoLink(
        to: ["unsubscribe@fjord-outdoor.example"], subject: "unsubscribe 8f2a11"))

    init() throws {
        client = JMAPClient(token: "demo", transport: server, maxRetries: 0)
        store = try MailStore()
    }

    func unsubscriber(receiver: ListUnsubscribe.Receiver = .fastmail) -> Unsubscriber {
        Unsubscriber(client: client, store: store, oneClick: oneClick, receiver: receiver, resolver: resolver)
    }

    func newsletter() async throws -> Email {
        try #require(try await client.emails(ids: ["e4"], properties: Email.Properties.full).first)
    }

    func mask() async throws -> MaskedEmail {
        try #require(try await client.maskedEmails().first { $0.email == "fjord.k3x9@fastmail.com" })
    }

    func offer(_ unsubscriber: Unsubscriber? = nil) async throws -> UnsubscribeOffer {
        let unsubscriber = unsubscriber ?? self.unsubscriber()
        return try #require(await unsubscriber.offer(for: try await newsletter(), isJunk: false, deliveredTo: try await mask()))
    }

    // MARK: Offers

    @Test func theNewsletterOffersOneClickFirstWithItsMaskedAddress() async throws {
        let offer = try await offer()

        #expect(offer.methods == [.oneClick(Self.oneClickURL), Self.mailto, .web(Self.oneClickURL)])
        #expect(offer.listName == "Fjord Outdoor")
        #expect(offer.listKey == "news.fjord-outdoor.example")
        #expect(offer.maskedAddress?.email == "fjord.k3x9@fastmail.com")
        #expect(offer.previous == nil)
        #expect(offer.previousRequestDate == nil)
    }

    @Test func verdictsOfAnotherReceiverDontCount() async throws {
        let offer = try await offer(unsubscriber(receiver: .init(domain: "mail.example.net")))

        #expect(offer.methods == [Self.mailto, .web(Self.oneClickURL)])
    }

    @Test func junkAndPhishingGetNoOffer() async throws {
        let unsubscriber = unsubscriber()
        #expect(await unsubscriber.offer(for: try await newsletter(), isJunk: true, deliveredTo: nil) == nil)

        try await client.updateEmails(["e4": .setKeyword(.phishing, true)])
        #expect(await unsubscriber.offer(for: try await newsletter(), isJunk: false, deliveredTo: nil) == nil)
    }

    @Test func offlineOnlyTheWaysThatAskTheUserAreOffered() async throws {
        let email = try await newsletter()
        server.isOffline = true

        let offer = try #require(await unsubscriber().offer(for: email, isJunk: false, deliveredTo: nil))

        #expect(offer.methods == [Self.mailto, .web(Self.oneClickURL)])
        #expect(offer.listKey == "news.fjord-outdoor.example")
    }

    @Test func mailWithoutListHeadersGetsNoOffer() async throws {
        let email = try #require(try await client.emails(ids: ["e3"], properties: Email.Properties.full).first)

        #expect(await unsubscriber().offer(for: email, isJunk: false, deliveredTo: nil) == nil)
    }

    // MARK: One-click

    @Test func oneClickPostsExactlyWhatRFC8058Asks() async throws {
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)

        let outcome = await unsubscriber.unsubscribe(offer, using: .oneClick(Self.oneClickURL), from: nil) { _ in }

        #expect(outcome == .requested)
        #expect(resolver.hosts == ["fjord-outdoor.example"])
        let request = try #require(oneClick.requests.first)
        #expect(oneClick.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://fjord-outdoor.example/unsubscribe/one-click?u=8f2a11&l=news")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.httpBody == Data("List-Unsubscribe=One-Click".utf8))
        #expect(request.httpBody?.count == 26)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "*")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 30)

        let record = try #require(try await store.unsubscription(listKey: "news.fjord-outdoor.example"))
        #expect(record.method == "oneClick")
        #expect(record.outcome == "requested")
    }

    @Test func theDemoAccountTakesOneClickRequestsItself() async throws {
        // The app's demo mode: the demo server answers the newsletter's one-click URL, whose host doesn't resolve.
        let unsubscriber = Unsubscriber(
            client: client, store: store, oneClick: server, resolver: FixedHostResolver(["93.184.216.34"]))
        let offer = try await offer(unsubscriber)

        #expect(await unsubscriber.unsubscribe(offer, using: .oneClick(Self.oneClickURL), from: nil) { _ in } == .requested)
        #expect(server.oneClickRequests.map(\.url) == [Self.oneClickURL])
        #expect(server.oneClickRequests.first?.httpBody == Data(ListUnsubscribe.oneClickBody.utf8))
    }

    @Test(arguments: [["192.168.1.10"], ["93.184.216.34", "10.0.0.1"], ["::1"], ["fe80::1%en0"], []])
    func aHostThatResolvesIntoAPrivateNetworkIsRefused(addresses: [String]) async throws {
        resolver.answer = addresses
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)

        let outcome = await unsubscriber.unsubscribe(offer, using: .oneClick(Self.oneClickURL), from: nil) { _ in }

        #expect(outcome == .refusedTarget)
        #expect(oneClick.requests.isEmpty)
        #expect(try await store.unsubscription(listKey: offer.listKey)?.outcome.hasPrefix("failed:") == true)
    }

    @Test func theSystemResolverAnswersWithNumericAddresses() async throws {
        let addresses = try await SystemHostResolver().addresses(of: "localhost")

        #expect(!addresses.isEmpty)
        #expect(Set(addresses).isSubset(of: ["127.0.0.1", "::1"]))
        #expect(!addresses.contains { UnsubscribeTarget.isPublic(address: $0) })
        await #expect(throws: HostResolutionError.self) {
            try await SystemHostResolver().addresses(of: "no-such-host.invalid")
        }
    }

    @Test func aTargetThatIsNoPublicNameIsNeitherResolvedNorAsked() async throws {
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)

        let outcome = await unsubscriber.unsubscribe(
            offer, using: .oneClick(URL(string: "https://192.168.1.10/unsubscribe")!), from: nil) { _ in }

        #expect(outcome == .refusedTarget)
        #expect(resolver.hosts.isEmpty)
        #expect(oneClick.requests.isEmpty)
    }

    @Test func whatTheListAnswers() async throws {
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)
        func unsubscribe() async -> UnsubscribeOutcome {
            await unsubscriber.unsubscribe(offer, using: .oneClick(Self.oneClickURL), from: nil) { _ in }
        }

        oneClick.status = 303
        #expect(await unsubscribe() == .requestedButRedirected)
        #expect(try await store.unsubscription(listKey: offer.listKey)?.outcome == "redirected")

        oneClick.status = 404
        #expect(await unsubscribe() == .failed("The list didn't accept the request (HTTP 404)."))
        #expect(try await store.unsubscription(listKey: offer.listKey)?.outcome
                == "failed:The list didn't accept the request (HTTP 404).")

        oneClick.failure = URLError(.timedOut)
        #expect(await unsubscribe() == .failed("Couldn't reach the list's server."))

        resolver.failure = HostResolutionError(code: EAI_NONAME)
        #expect(await unsubscribe() == .failed("Couldn't find the list's server."))
    }

    // MARK: Mail and web

    @Test func mailtoQueuesAPlainDraftFromTheMaskedAddress() async throws {
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)
        var sent: [MessageDraft] = []

        let outcome = await unsubscriber.unsubscribe(
            offer, using: Self.mailto, from: EmailAddress(name: "Alex Berg", email: "fjord.k3x9@fastmail.com")
        ) { sent.append($0) }

        #expect(outcome == .mailQueued)
        let draft = try #require(sent.first)
        #expect(sent.count == 1)
        #expect(draft.from == EmailAddress(email: "fjord.k3x9@fastmail.com"))
        #expect(draft.to == [EmailAddress(email: "unsubscribe@fjord-outdoor.example")])
        #expect(draft.cc.isEmpty && draft.bcc.isEmpty && draft.replyTo.isEmpty)
        #expect(draft.subject == "unsubscribe 8f2a11")
        #expect(draft.body == AttributedString())
        #expect(!draft.includesSignature)
        #expect(draft.kind == .new)
        #expect(draft.messageIDDomain == "fastmail.com")
        #expect(oneClick.requests.isEmpty)
        let record = try #require(try await store.unsubscription(listKey: offer.listKey))
        #expect(record.method == "mailto")
        #expect(record.outcome == "queued")
    }

    @Test func aMailtoThatCantBeQueuedFails() async throws {
        struct Refusal: Error, LocalizedError {
            var errorDescription: String? { "Fastmail needs a sending identity for this address." }
        }
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)

        #expect(await unsubscriber.unsubscribe(offer, using: Self.mailto, from: EmailAddress(email: "fjord.k3x9@fastmail.com")) { _ in
            throw Refusal()
        } == .failed("Fastmail needs a sending identity for this address."))
        #expect(await unsubscriber.unsubscribe(offer, using: Self.mailto, from: nil) { _ in }
                == .failed("There's no address to send the unsubscribe message from."))
        #expect(try await store.unsubscription(listKey: offer.listKey)?.method == "mailto")
        #expect(try await store.unsubscription(listKey: offer.listKey)?.outcome.hasPrefix("failed:") == true)
    }

    @Test func mailtoDraftsKeepWhatTheLinkSays() {
        let draft = unsubscriber().mailtoDraft(
            MailtoLink(to: ["leave@list.example", "list@list.example"], body: "remove me\nplease"),
            from: EmailAddress(email: "alex@fastmail.com"))

        #expect(draft.to.map(\.email) == ["leave@list.example", "list@list.example"])
        #expect(draft.subject == "unsubscribe")
        #expect(String(draft.body.characters) == "remove me\nplease")
    }

    @Test func theWebPageIsOpenedPrivately() async throws {
        let unsubscriber = unsubscriber()
        let offer = try await offer(unsubscriber)

        #expect(await unsubscriber.unsubscribe(offer, using: .web(Self.oneClickURL), from: nil) { _ in }
                == .openPage(Self.oneClickURL))
        #expect(oneClick.requests.isEmpty)
        let record = try #require(try await store.unsubscription(listKey: offer.listKey))
        #expect(record.method == "web")
        #expect(record.outcome == "opened")

        // Only the page knows whether it took the request, so the next offer claims none.
        let next = try await self.offer(unsubscriber)
        #expect(next.previous?.method == "web")
        #expect(next.previousRequestDate == nil)
    }

    // MARK: Records

    @Test func theNextOfferKnowsTheLastRequest() async throws {
        let unsubscriber = unsubscriber()
        let first = try await offer(unsubscriber)
        _ = await unsubscriber.unsubscribe(first, using: .oneClick(Self.oneClickURL), from: nil) { _ in }

        let second = try await offer(unsubscriber)
        #expect(second.previous?.method == "oneClick")
        #expect(second.previousRequestDate == second.previous?.requestedAt)
        #expect(second.previousRequestDate != nil)

        oneClick.status = 500
        _ = await unsubscriber.unsubscribe(second, using: .oneClick(Self.oneClickURL), from: nil) { _ in }
        let third = try await offer(unsubscriber)
        #expect(third.previous?.outcome.hasPrefix("failed:") == true)
        #expect(third.previousRequestDate == nil)

        await unsubscriber.recordMaskDisabled(third)
        let fourth = try await offer(unsubscriber)
        #expect(fourth.previous?.method == "disableMask")
        #expect(fourth.previousRequestDate != nil)
    }

    @Test func listsAreNamedAndKeyedByListIdElseSender() {
        #expect(Unsubscriber.listID("Fjord Outdoor News <news.fjord-outdoor.example>")?.id == "news.fjord-outdoor.example")
        #expect(Unsubscriber.listID("Fjord Outdoor News <news.fjord-outdoor.example>")?.phrase == "Fjord Outdoor News")
        #expect(Unsubscriber.listID("\"Quoted List\" < list.example >")?.phrase == "Quoted List")
        #expect(Unsubscriber.listID("list.example")?.id == "list.example")
        #expect(Unsubscriber.listID("  ") == nil)

        let listID = Unsubscriber.listID("News <news.example>")
        #expect(Unsubscriber.listName(sender: EmailAddress(name: "Fjord Outdoor", email: "a@b.example"), listID: listID)
                == "Fjord Outdoor")
        #expect(Unsubscriber.listName(sender: EmailAddress(email: "a@b.example"), listID: listID) == "News")
        #expect(Unsubscriber.listName(sender: EmailAddress(email: "a@b.example"), listID: nil) == "a@b.example")
        #expect(Unsubscriber.listName(sender: nil, listID: Unsubscriber.listID("news.example")) == "news.example")
    }
}

/// Records the one-click requests and answers them with `status`, or fails with `failure`.
final class UnsubscriberTestsTransport: HTTPTransport {
    private struct State {
        var requests: [URLRequest] = []
        var status = 200
        var failure: URLError?
    }

    private let state = Mutex(State())

    var requests: [URLRequest] { state.withLock { $0.requests } }

    var status: Int {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var failure: URLError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, failure) = state.withLock { state in
            state.requests.append(request)
            return (state.status, state.failure)
        }
        if let failure { throw failure }
        let headers = (300..<400).contains(status) ? ["Location": "https://fjord-outdoor.example/bye"] : [:]
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// Answers every lookup with `answer`, or fails with `failure`, and records the hosts it was asked for.
final class UnsubscriberTestsResolver: HostResolver {
    private struct State {
        var answer = ["93.184.216.34"]
        var failure: HostResolutionError?
        var hosts: [String] = []
    }

    private let state = Mutex(State())

    var answer: [String] {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }

    var failure: HostResolutionError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    var hosts: [String] { state.withLock { $0.hosts } }

    func addresses(of host: String) async throws -> [String] {
        let (answer, failure) = state.withLock { state in
            state.hosts.append(host)
            return (state.answer, state.failure)
        }
        if let failure { throw failure }
        return answer
    }
}
