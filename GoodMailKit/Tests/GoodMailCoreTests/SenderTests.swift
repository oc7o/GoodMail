import DemoAccount
import Foundation
import JMAPKit
import MailCompose
import Testing
@testable import GoodMailCore

/// Which address mail goes out from (D19–D21), against the demo account: `ident-1` is alex@fastmail.com,
/// `ident-2` the wildcard *@berg.example, and six masked addresses in every state.
@MainActor
struct SenderTests {
    let account: OutboxTestAccount
    var model: MailModel { account.model }

    init() throws {
        account = try OutboxTestAccount()
    }

    private func email(_ json: String) throws -> Email {
        try JMAPCoding.makeDecoder().decode(Email.self, from: Data(json.utf8))
    }

    @Test func repliesComeFromWhereTheOriginalArrived() async throws {
        await account.start()
        let emails = try await account.client.emails(ids: ["e3", "e4", "e7", "e15"])
        func sender(_ id: String) -> SenderChoice? { model.sender(for: emails.first { $0.id == id }) }

        #expect(sender("e3") == SenderChoice(
            address: EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"), reason: .deliveredToIdentity))
        #expect(sender("e4") == SenderChoice(address: EmailAddress(email: "fjord.k3x9@fastmail.com"), reason: .deliveredToMask))
        #expect(sender("e7") == SenderChoice(address: EmailAddress(email: "paperplane.x2m4@fastmail.com"), reason: .deliveredToMask))
        // A draft of the user's own: from them, to someone else.
        #expect(sender("e15")?.reason == .originalFromYou)
        #expect(model.sender(for: nil) == SenderChoice(
            address: EmailAddress(name: "Alex Berg", email: "alex@fastmail.com"), reason: .defaultIdentity))
    }

    @Test func aMaskReachedThroughBccIsFoundByWhereFastmailDeliveredIt() async throws {
        await account.start()
        let original = try email(#"""
            {"id": "x1", "from": [{"name": "Shop", "email": "deals@shop.example"}],
             "to": [{"name": null, "email": "everyone@lists.example"}],
             "header:X-Delivered-To:asAddresses:all": [[{"name": null, "email": "parcel.q8w1@fastmail.com"}]]}
            """#)

        #expect(model.sender(for: original)?.address.email == "parcel.q8w1@fastmail.com")
        #expect(model.maskedEmail(for: original)?.id == "masked-3")
        #expect(model.isOwnAddress("parcel.q8w1@fastmail.com"))
        #expect(!model.isOwnAddress("everyone@lists.example"))
    }

    @Test func identitiesComeBeforeWhereFastmailDeliveredIt() async throws {
        await account.start()
        // Delivered through an alias whose X-Delivered-To names the login, To names the wildcard address.
        let original = try email(#"""
            {"id": "x2", "from": [{"name": "Jonas", "email": "jonas@weber.example"}],
             "to": [{"name": null, "email": "shop@berg.example"}],
             "header:X-Delivered-To:asAddresses:all": [[{"name": null, "email": "alex@fastmail.com"}]]}
            """#)

        #expect(model.sender(for: original) == SenderChoice(
            address: EmailAddress(name: "Alex Berg", email: "shop@berg.example"), reason: .deliveredToIdentity))
        #expect(model.isOwnAddress("SHOP@berg.example"))
        #expect(model.isOwnAddress("anything@berg.example"))
        #expect(model.isOwnAddress("someone@else.example", in: try email(#"""
            {"id": "x3", "header:X-Delivered-To:asAddresses:all": [[{"name": null, "email": "someone@else.example"}]]}
            """#)))
    }

    @Test func withoutIdentitiesTheLoginNameIsTheSender() {
        let directory = SenderDirectory(login: "alex@fastmail.com")

        #expect(directory.sender(for: nil) == SenderChoice(address: EmailAddress(email: "alex@fastmail.com"), reason: .loginName))
        #expect(directory.options().map(\.kind) == [.login])
        #expect(SenderDirectory().sender(for: nil) == nil)
    }

    @Test func theDefaultIdentityIsTheLoginsElseOneThatCantBeDeleted() {
        let fixed = Identity(id: "I1", name: "Alex", email: "alex@berg.example", mayDelete: false)
        let other = Identity(id: "I2", email: "other@berg.example", mayDelete: true)
        let login = Identity(id: "I3", email: "alex@fastmail.com", mayDelete: true)

        #expect(SenderDirectory(login: "alex@fastmail.com", identities: [other, fixed, login]).defaultIdentity == login)
        #expect(SenderDirectory(login: "alex@fastmail.com", identities: [other, fixed]).defaultIdentity == fixed)
    }

    @Test func theFromMenuListsIdentitiesThenMasksByState() async throws {
        await account.start()

        let options = model.senderOptions()

        #expect(options.map(\.address.email) == [
            "alex@fastmail.com", "fjord.k3x9@fastmail.com", "paperplane.x2m4@fastmail.com",
            "parcel.q8w1@fastmail.com", "quiet.harbor.1182@fastmail.com", "win.a7b2@fastmail.com",
        ])
        #expect(options.first?.address.name == "Alex Berg")
        #expect(options.dropFirst().allSatisfy { $0.needsSendingIdentity && $0.address.name == nil })
        #expect(options.last?.kind == .masked(id: "masked-4", state: .disabled))
    }

    @Test func hiddenIdentitiesStayOutOfTheMenuButStillSend() {
        let shown = Identity(id: "I1", name: "Alex", email: "alex@fastmail.com")
        let hidden = Identity(id: "I2", name: "Old", email: "old@fastmail.com")
        let directory = SenderDirectory(
            login: "alex@fastmail.com", identities: [shown, hidden], hiddenIdentityIDs: ["I2"])

        #expect(directory.options().map(\.address.email) == ["alex@fastmail.com"])
        #expect(directory.identity(for: "old@fastmail.com") == hidden)
    }

    @Test func aMaskWithItsOwnIdentityNeedsNoneCreated() {
        let mask = MaskedEmail.make(id: "m1", email: "fjord.k3x9@fastmail.com")
        let identity = Identity(id: "I9", email: "fjord.k3x9@fastmail.com", mayDelete: true)
        let without = SenderDirectory(login: "alex@fastmail.com", maskedEmails: ["fjord.k3x9@fastmail.com": mask])
        var with = without
        with.identities = [identity]

        #expect(without.needsSendingIdentity(for: "fjord.k3x9@fastmail.com", policy: MaskedSending()))
        #expect(!with.needsSendingIdentity(for: "fjord.k3x9@fastmail.com", policy: MaskedSending()))
        #expect(with.options().map(\.kind) == [.masked(id: "m1", state: .enabled)])
        #expect(with.options().first?.needsSendingIdentity == false)
        #expect(without.sendingIdentity(for: "fjord.k3x9@fastmail.com", consent: "fjord.k3x9@fastmail.com",
                                        policy: MaskedSending()) == .missingForMask("fjord.k3x9@fastmail.com"))
        #expect(without.sendingIdentity(for: "fjord.k3x9@fastmail.com", consent: "FJORD.k3x9@fastmail.com",
                                        policy: MaskedSending(createsIdentities: true)) == .create("fjord.k3x9@fastmail.com"))
        #expect(without.sendingIdentity(for: "fjord.k3x9@fastmail.com", consent: "paperplane.x2m4@fastmail.com",
                                        policy: MaskedSending(createsIdentities: true))
            == .missingForMask("fjord.k3x9@fastmail.com"))
    }

    @Test func maskedAddressesSendWithoutNameOrSignature() async throws {
        await account.start()
        let composer = try await model.compose(.new())
        #expect(composer.signature == Signature(html: "<div>Alex</div>", text: "-- \nAlex"))

        composer.from = EmailAddress(name: "Alex Berg", email: "fjord.k3x9@fastmail.com")

        #expect(composer.from == EmailAddress(email: "fjord.k3x9@fastmail.com"))
        #expect(composer.signature == nil)
        composer.from = EmailAddress(name: "Alex Berg", email: "alex@fastmail.com")
        #expect(composer.signature == Signature(html: "<div>Alex</div>", text: "-- \nAlex"))
    }

    @Test func identitiesAreReadWithFastmailsComposeFlag() throws {
        let json = #"""
            [{"id": "I1", "name": "Alex", "email": "alex@fastmail.com", "showInCompose": false, "saveOnSend": true},
             {"id": "I2", "email": "*@berg.example"}]
            """#
        let listed = try JSONDecoder().decode([ListedIdentity].self, from: Data(json.utf8))

        #expect(listed.map(\.showInCompose) == [false, true])
        #expect(listed.map(\.identity) == [
            Identity(id: "I1", name: "Alex", email: "alex@fastmail.com"), Identity(id: "I2", email: "*@berg.example"),
        ])
    }

    @Test func theAccountSnapshotKeepsWhatTheServerTaughtForTheSameAccount() async throws {
        await account.start()
        let session = try await account.client.session()
        let snapshot = try #require(model.account)
        #expect(snapshot.username == "alex@fastmail.com")
        #expect(snapshot.canSubmit && snapshot.sendAvailability == .available)
        #expect(snapshot.maxSizeAttachmentsPerEmail == 50_000_000 && snapshot.maxSizeRequest == 10_000_000)
        #expect(snapshot.maxDelayedSend == 44_236_800 && snapshot.holdsOnServer)
        #expect(snapshot.identities.map(\.id) == ["ident-1", "ident-2"])

        var refused = snapshot
        refused.serverHoldUnsupported = true
        let again = try #require(AccountSnapshot(session: session, previous: refused, at: .now))
        #expect(again.serverHoldUnsupported && !again.holdsOnServer)
        #expect(again.identities == snapshot.identities)

        var other = refused
        other.mailAccountID = "someone-else"
        let fresh = try #require(AccountSnapshot(session: session, previous: other, at: .now))
        #expect(!fresh.serverHoldUnsupported && fresh.identities.isEmpty)
    }
}

extension MaskedEmail {
    /// A masked address for tests that need no server.
    fileprivate static func make(id: String, email: String, state: MaskedEmail.State = .enabled) -> MaskedEmail {
        let json = #"{"id": "\#(id)", "email": "\#(email)", "state": "\#(state.rawValue)"}"#
        return try! JMAPCoding.makeDecoder().decode(MaskedEmail.self, from: Data(json.utf8))
    }
}
