import Foundation
import Testing
@testable import MailPrivacy

struct ListUnsubscribeTests {
    static let oneClickURL = "https://fjord-outdoor.example/unsubscribe/one-click?u=8f2a11"
    static let mailtoURL = "mailto:unsubscribe@fjord-outdoor.example?subject=unsubscribe"
    static let signature = """
         v=1; a=rsa-sha256; c=relaxed/relaxed; d=fjord-outdoor.example; s=fm1;\r
        \th=from:to:subject:list-unsubscribe:list-unsubscribe-post; bh=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=;\r
        \tb=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdEfGhIjKlMnOpQrStUvWx\r
        \t yz0123456789==
        """
    static let verdict = """
         phl-mx-03.messagingengine.com;\r
            arc=none (no signatures found);\r
            dkim=pass (2048-bit rsa key sha256) header.d=fjord-outdoor.example\r
              header.i=@fjord-outdoor.example header.b=AbCdEfGh header.a=rsa-sha256\r
              header.s=fm1 x-bits=2048;\r
            dmarc=pass policy.published-domain-policy=none (p=none,d=none,d.eval=none)\r
              header.from=fjord-outdoor.example;\r
            spf=pass smtp.mailfrom=bounce@fjord-outdoor.example smtp.helo=mail.fjord-outdoor.example
        """
    /// The Received field with which Fastmail's MX accepted the message from the list's server.
    static func arrival(helo: String = "mail.fjord-outdoor.example",
                        connection: String = "mail.fjord-outdoor.example [93.184.216.34]") -> String {
        """
         from \(helo) (\(connection))\r
        \t(using TLSv1.3 with cipher TLS_AES_256_GCM_SHA384 (256/256 bits)\r
        \t key-exchange X25519 server-signature RSA-PSS (2048 bits) server-digest SHA256)\r
        \t(No client certificate requested)\r
        \tby phl-mx-03.messagingengine.com (Postfix) with ESMTPS\r
        \tfor <fjord.k3x9@fastmail.com>; Fri,  9 Oct 2026 08:12:39 -0400 (EDT)
        """
    }

    /// Fastmail's layout, topmost first: its internal hops, its verdicts with the DKIM one not on top, the MX's
    /// Received field, then what came with the message, a forged Fastmail verdict among it.
    static func fastmailHeaders(
        verdict: String = ListUnsubscribeTests.verdict, arrival: String = ListUnsubscribeTests.arrival(),
        cameWithMessage: [ListUnsubscribe.HeaderField] = []
    ) -> [ListUnsubscribe.HeaderField] {
        [
            .init(name: "Received", value: """
                 from phl-compute-04.internal (phl-compute-04.internal [10.202.2.44])\r
                \t by phl-imap-12 (Cyrus 3.13.0-alpha0-1288-gd1f3c3c4b-fm-20260924.001) with LMTPA;\r
                \t Fri, 09 Oct 2026 08:12:40 -0400
                """),
            .init(name: "X-Delivered-to", value: " fjord.k3x9@fastmail.com"),
            .init(name: "Received", value: """
                 from phl-mx-03 ([10.202.2.202])\r
                  by phl-compute-04.internal (LMTPProxy); Fri, 09 Oct 2026 08:12:40 -0400
                """),
            .init(name: "Received", value: """
                 from phl-mx-03.messagingengine.com (localhost [127.0.0.1])\r
                \tby phl-mx-03.messagingengine.com (Authentication Milter) with ESMTP\r
                \tid 5F2C81A0091; Fri, 09 Oct 2026 08:12:40 -0400
                """),
            .init(name: "Authentication-Results", value: " phl-mx-03.messagingengine.com;\r\n    x-csa=none;\r\n    x-me-sender=none"),
            .init(name: "Authentication-Results", value: " phl-mx-03.messagingengine.com;\r\n    bimi=skipped (DMARC Policy is not at enforcement)"),
            .init(name: "Authentication-Results", value: verdict),
            .init(name: "Received", value: arrival),
        ] + cameWithMessage + [
            .init(name: "DKIM-Signature", value: signature),
            .init(name: "From", value: " Fjord Outdoor <news@fjord-outdoor.example>"),
            .init(name: "List-Unsubscribe", value: " <\(oneClickURL)>, <\(mailtoURL)>"),
            .init(name: "List-Unsubscribe-Post", value: " List-Unsubscribe=One-Click"),
        ]
    }

    /// A verdict claiming that the list's own signature passed, as anyone can write into a message.
    static let forgedPass = ListUnsubscribe.HeaderField(name: "Authentication-Results", value: """
         phl-mx-01.messagingengine.com;\r
            dkim=pass header.d=fjord-outdoor.example header.b=AbCdEfGh
        """)
    /// The real verdict, had the signature not verified.
    static let failingVerdict = verdict.replacingOccurrences(of: "dkim=pass", with: "dkim=fail")

    struct Headers {
        var listUnsubscribe = [[ListUnsubscribeTests.mailtoURL, ListUnsubscribeTests.oneClickURL]]
        var listUnsubscribePost = ["List-Unsubscribe=One-Click"]
        var headers = ListUnsubscribeTests.fastmailHeaders()
        var receiver = ListUnsubscribe.Receiver.fastmail

        var methods: [ListUnsubscribe.Method] {
            ListUnsubscribe.methods(
                listUnsubscribe: listUnsubscribe, listUnsubscribePost: listUnsubscribePost, headers: headers,
                receiver: receiver)
        }

        var offersOneClick: Bool {
            methods.contains { if case .oneClick = $0 { true } else { false } }
        }

        mutating func replace(_ name: String, with values: [String]) {
            let index = headers.firstIndex { $0.name == name } ?? headers.endIndex
            headers.removeAll { $0.name == name }
            headers.insert(contentsOf: values.map { .init(name: name, value: $0) }, at: min(index, headers.endIndex))
        }
    }

    static let mailto = ListUnsubscribe.Method.mailto(MailtoLink(URL(string: mailtoURL)!)!)
    static let web = ListUnsubscribe.Method.web(URL(string: oneClickURL)!)

    // MARK: Fastmail's verdicts

    @Test func oneClickFirstWhenEverythingChecksOut() {
        #expect(Headers().methods == [.oneClick(URL(string: Self.oneClickURL)!), Self.mailto, Self.web])
    }

    @Test func fastmailsVerdictsAreThoseAboveItsMXsReceivedField() throws {
        let verdicts = try #require(ListUnsubscribe.receiverVerdicts(
            in: Self.fastmailHeaders(cameWithMessage: [Self.forgedPass]), receiver: .fastmail))

        #expect(verdicts.map(\.authServID) == Array(repeating: "phl-mx-03.messagingengine.com", count: 3))
        // The topmost one never holds the DKIM verdict.
        #expect(verdicts.map(\.dkimPasses.count) == [0, 0, 1])
    }

    @Test func withoutTheMXsReceivedFieldNothingCanBeTold() {
        var headers = Headers()
        headers.headers.removeAll { $0.value.contains("(Postfix) with ESMTPS") }

        #expect(ListUnsubscribe.receiverVerdicts(in: headers.headers, receiver: .fastmail) == nil)
        #expect(headers.methods == [Self.mailto, Self.web])
    }

    @Test func aPassThatCameWithTheMessageDoesntCount() {
        var headers = Headers()
        headers.headers = Self.fastmailHeaders(verdict: Self.failingVerdict, cameWithMessage: [Self.forgedPass])
        #expect(!headers.offersOneClick)

        // A forged hop of Fastmail's own below the real one doesn't move the boundary down either.
        headers.headers = Self.fastmailHeaders(verdict: Self.failingVerdict, cameWithMessage: [
            Self.forgedPass,
            .init(name: "Received", value: Self.arrival().replacingOccurrences(of: "93.184.216.34", with: "93.184.216.35")),
        ])
        #expect(!headers.offersOneClick)
    }

    @Test(arguments: [
        ("phl-mx-09.messagingengine.com", "unknown [93.184.216.34]"),
        ("localhost", "mail.evil.example [93.184.216.34]"),
        ("relay.internal", "unknown [93.184.216.34]"),
        ("[10.0.0.1]", "unknown [93.184.216.34]"),
        ("relay.internal", "relay.internal [93.184.216.34]"),
        ("relay.internal", "[93.184.216.34] helo=relay.internal"),
    ])
    func aSenderPosingAsFastmailDoesntMoveTheBoundary(helo: String, connection: String) {
        // Were the MX's hop taken for an internal one, the forged hop and its forged pass below would count.
        var headers = Headers()
        headers.headers = Self.fastmailHeaders(
            verdict: Self.failingVerdict, arrival: Self.arrival(helo: helo, connection: connection),
            cameWithMessage: [
                Self.forgedPass,
                .init(name: "Received", value: Self.arrival()),
            ])

        #expect(!headers.offersOneClick)
    }

    @Test func fastmailsOwnHopsAreSkipped() {
        let hops = [
            " from phl-mx-03.messagingengine.com (localhost [127.0.0.1])\r\n\tby phl-mx-03.messagingengine.com (Authentication Milter) with ESMTP",
            " from phl-out-01.internal (phl-out-01.internal [10.0.0.9])\r\n\tby phl-mx-01.messagingengine.com (Postfix) with ESMTPS",
            " from [IPv6:fd00::5] ([IPv6:fd00::5]) by phl-mx-01.messagingengine.com (Postfix)",
            " by phl-mx-03.messagingengine.com (Postfix, from userid 0) id 4B1C2A0091",
        ]
        for hop in hops {
            let field = ReceivedField(hop)
            #expect(field.isReadable, "\(hop)")
            #expect(field.isFrom(within: .fastmail), "\(hop)")
        }
        #expect(!ReceivedField(Self.arrival()).isFrom(within: .fastmail))
        #expect(ReceivedField(Self.arrival()).byHost == "phl-mx-03.messagingengine.com")
    }

    @Test(arguments: [
        " from relay.internal( (unknown [93.184.216.34]) by phl-mx-03.messagingengine.com (Postfix)",
        " from a(b)c (unknown [93.184.216.34]) by phl-mx-03.messagingengine.com (Postfix)",
        " from relay.internal) by phl-mx-03.messagingengine.com (Postfix)",
        " from \"relay.internal by phl-mx-03.messagingengine.com",
        " (qmail 4312 invoked by uid 89); 9 Oct 2026 12:12:39 -0000",
    ])
    func anUnreadableReceivedFieldAboveTheBoundaryEndsTheSearch(hop: String) {
        // Placed above the MX's hop, where only Fastmail writes; the sender controls the HELO name of that hop.
        var headers = Headers()
        headers.headers.insert(.init(name: "Received", value: hop), at: 1)

        #expect(!ReceivedField(hop).isReadable)
        #expect(!headers.offersOneClick)

        var arrival = Headers()
        arrival.headers = Self.fastmailHeaders(arrival: hop)
        #expect(!arrival.offersOneClick)
    }

    @Test func clausesAreReadByPositionNotByKeyword() throws {
        // A HELO name "by" mustn't pass for the by clause.
        let hop = " from by (unknown [93.184.216.34]) by phl-mx-03.messagingengine.com (Postfix)"
        let field = ReceivedField(hop)
        #expect(try #require(field.from).text == "by")
        #expect(field.byHost == "phl-mx-03.messagingengine.com")
        #expect(!field.isFrom(within: .fastmail))

        var headers = Headers()
        headers.headers = Self.fastmailHeaders(arrival: hop)
        #expect(headers.offersOneClick)
    }

    @Test func everyVerdictAboveTheBoundaryMustBeFastmails() {
        var headers = Headers()
        headers.headers.insert(.init(name: "Authentication-Results", value: " phl-compute-04.internal; none"), at: 4)
        #expect(!headers.offersOneClick)

        var unreadable = Headers()
        unreadable.headers.insert(.init(name: "Authentication-Results", value: " "), at: 4)
        #expect(!unreadable.offersOneClick)

        var lookalike = Headers()
        lookalike.headers = Self.fastmailHeaders(verdict: Self.verdict.replacingOccurrences(
            of: "phl-mx-03.messagingengine.com", with: "phl-mx-03.evilmessagingengine.com"))
        #expect(!lookalike.offersOneClick)
    }

    @Test func anotherReceiverTrustsNoneOfFastmailsVerdicts() {
        var headers = Headers()
        headers.receiver = .init(domain: "mail.example.net")
        #expect(headers.methods == [Self.mailto, Self.web])
    }

    // MARK: Pairing with a signature

    @Test func noOneClickWithoutDKIM() {
        var headers = Headers()
        headers.headers.removeAll { $0.name == "DKIM-Signature" }
        #expect(!headers.offersOneClick)
    }

    @Test func noOneClickWhenTheSignatureDoesNotCoverThePostHeader() {
        var headers = Headers()
        headers.replace("DKIM-Signature", with: [Self.signature.replacingOccurrences(of: ":list-unsubscribe-post", with: "")])
        #expect(!headers.offersOneClick)
    }

    @Test func duplicateHeadersDisableOneClick() {
        var headers = Headers()
        headers.listUnsubscribe = [[Self.oneClickURL], [Self.mailtoURL, Self.oneClickURL]]
        #expect(!headers.offersOneClick)
        #expect(headers.methods == [Self.mailto, Self.web])

        var posts = Headers()
        posts.listUnsubscribePost = ["List-Unsubscribe=One-Click", "List-Unsubscribe=One-Click"]
        #expect(!posts.offersOneClick)
    }

    @Test func failingDKIMDisablesOneClick() {
        var headers = Headers()
        headers.headers = Self.fastmailHeaders(verdict: Self.failingVerdict)
        #expect(!headers.offersOneClick)
    }

    @Test(arguments: ["AbCdEfG", "AbCdEfGX", "abcdefgh"])
    func signaturePrefixMustBeLongAndMatch(prefix: String) {
        var headers = Headers()
        headers.headers = Self.fastmailHeaders(
            verdict: Self.verdict.replacingOccurrences(of: "header.b=AbCdEfGh", with: "header.b=\(prefix)"))
        #expect(!headers.offersOneClick)
    }

    @Test func aLongerMatchingPrefixWorks() {
        var headers = Headers()
        headers.headers = Self.fastmailHeaders(
            verdict: Self.verdict.replacingOccurrences(of: "header.b=AbCdEfGh", with: "header.b=AbCdEfGhIjKlMnOp"))
        #expect(headers.offersOneClick)
    }

    @Test func aPrefixNamingTwoSignaturesPairsWithNeither() {
        // A second signature that shares the prefix could claim headers the verified one doesn't cover.
        var headers = Headers()
        headers.replace("DKIM-Signature", with: [
            Self.signature.replacingOccurrences(of: ":list-unsubscribe-post", with: ""),
            Self.signature.replacingOccurrences(of: "yz0123456789==", with: "yz0123456788=="),
        ])
        #expect(!headers.offersOneClick)
    }

    @Test func signingDomainMustMatch() {
        var headers = Headers()
        headers.headers = Self.fastmailHeaders(verdict: Self.verdict.replacingOccurrences(
            of: "header.d=fjord-outdoor.example", with: "header.d=mailer.example"))
        #expect(!headers.offersOneClick)
    }

    // MARK: Targets and parsing

    @Test func plainHTTPIsNeverOffered() {
        var headers = Headers()
        headers.listUnsubscribe = [["http://fjord-outdoor.example/unsubscribe?u=1"]]
        #expect(headers.methods.isEmpty)
    }

    @Test func mailtoOnly() {
        var headers = Headers()
        headers.listUnsubscribe = [[Self.mailtoURL]]
        #expect(headers.methods == [Self.mailto])
    }

    @Test func privateTargetsAreNeverOffered() {
        var headers = Headers()
        headers.listUnsubscribe = [["https://192.168.1.10/unsubscribe", "https://localhost/u"]]
        #expect(headers.methods.isEmpty)
    }

    @Test func rawHeaderValuesFollowRFC2369() {
        #expect(ListUnsubscribe.urls(inHeaderValue: "<https://a.example/u>, junk, <mailto:b@c.example>")
                == ["https://a.example/u"])
        #expect(ListUnsubscribe.urls(inHeaderValue: "junk <https://a.example/u>").isEmpty)
        #expect(ListUnsubscribe.urls(inHeaderValue: "<https://a.example/u> trailing, <mailto:b@c.example>")
                == ["https://a.example/u"])
        #expect(ListUnsubscribe.urls(inHeaderValue: "(comment) <https://a.example/u>,\r\n (more) < mailto:b@c.example >")
                == ["https://a.example/u", "mailto:b@c.example"])

        var headers = Headers()
        headers.listUnsubscribe = [["<\(Self.oneClickURL)>, see website, <\(Self.mailtoURL)>"]]
        #expect(headers.methods == [.oneClick(URL(string: Self.oneClickURL)!), Self.web])
    }

    @Test func parsedValuesStopAtTheFirstNonURL() {
        #expect(ListUnsubscribe.fallbackMethods(listUnsubscribe: [Self.oneClickURL, "not a url", Self.mailtoURL])
                == [Self.web])
    }

    @Test func fallbacksNeverIncludeOneClick() {
        #expect(ListUnsubscribe.fallbackMethods(listUnsubscribe: [Self.oneClickURL, Self.mailtoURL]) == [Self.mailto, Self.web])
    }

    @Test func parsesAuthenticationResults() throws {
        let results = try #require(AuthenticationResults("MX.Example.org 1; none"))
        #expect(results.authServID == "mx.example.org")
        #expect(results.dkimPasses.isEmpty)

        let spaced = try #require(AuthenticationResults(
            "mx.example.org; dkim = pass (good) header.d = Example.COM header.b = \"AbCdEfGh\"; spf=pass"))
        #expect(spaced.dkimPasses == [.init(domain: "example.com", signaturePrefix: "AbCdEfGh")])

        let folded = try #require(AuthenticationResults(Self.verdict))
        #expect(folded.authServID == "phl-mx-03.messagingengine.com")
        #expect(folded.dkimPasses == [.init(domain: "fjord-outdoor.example", signaturePrefix: "AbCdEfGh")])
    }

    @Test func parsesDKIMSignatures() throws {
        let signature = try #require(DKIMSignature(Self.signature))
        #expect(signature.domain == "fjord-outdoor.example")
        #expect(signature.signedHeaders == ["from", "to", "subject", "list-unsubscribe", "list-unsubscribe-post"])
        #expect(signature.signature == "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdEfGhIjKlMnOpQrStUvWxyz0123456789==")
        #expect(DKIMSignature("v=1; d=example.com") == nil)
    }

    @Test func parsesReceivedFields() throws {
        let arrival = ReceivedField(Self.arrival())
        let from = try #require(arrival.from)
        #expect(from.text == "mail.fjord-outdoor.example")
        #expect(from.comments.first == "mail.fjord-outdoor.example [93.184.216.34]")
        #expect(from.comments.count == 3)
        #expect(arrival.byHost == "phl-mx-03.messagingengine.com")

        let local = ReceivedField(" by Phl-MX-03.MessagingEngine.com. (Postfix, from userid 0) id 4B1C2A0091; Fri, 9 Oct 2026")
        #expect(local.from == nil)
        #expect(local.byHost == "phl-mx-03.messagingengine.com")

        let escaped = ReceivedField(#" from a.internal (localhost \) [127.0.0.1]) by b.internal; date"#)
        #expect(escaped.isReadable)
        #expect(escaped.from?.comments == ["localhost ) [127.0.0.1]"])
    }
}

struct MailtoLinkTests {
    @Test func decodesRecipientsSubjectAndBody() throws {
        let link = try #require(MailtoLink(URL(string:
            "mailto:list@x.example,second%40x.example?subject=Unsubscribe%20me&body=Please%0D%0Aremove%20me&to=third@x.example")!))
        #expect(link.to == ["list@x.example", "second@x.example", "third@x.example"])
        #expect(link.subject == "Unsubscribe me")
        #expect(link.body == "Please\nremove me")
    }

    @Test func ignoresEveryOtherHeader() throws {
        let link = try #require(MailtoLink(URL(string:
            "MAILTO:a@x.example?cc=evil@y.example&bcc=hidden@y.example&in-reply-to=%3Cid@y%3E&X-Custom=1&From=me@y.example")!))
        #expect(link == MailtoLink(to: ["a@x.example"]))
    }

    @Test func plusStaysAPlus() throws {
        let link = try #require(MailtoLink(URL(string: "mailto:a+list@x.example?subject=1+1&body=a+b")!))
        #expect(link.to == ["a+list@x.example"])
        #expect(link.subject == "1+1")
        #expect(link.body == "a+b")
    }

    @Test func onlyMailtoURLs() {
        #expect(MailtoLink(URL(string: "https://x.example/?to=a@b")!) == nil)
        #expect(MailtoLink(URL(string: "mailto:")!) == MailtoLink(to: []))
    }
}

struct UnsubscribeTargetTests {
    @Test(arguments: [
        ("https://list.example.com/unsubscribe?u=1", true),
        ("https://list.example.com:443/u", true),
        ("https://xn--bcher-kva.example/u", true),
        ("http://list.example.com/u", false),
        ("https://192.168.1.1/u", false),
        ("https://8.8.8.8/u", false),
        ("https://[::1]/u", false),
        ("https://[2606:4700::1111]/u", false),
        ("https://2130706433/u", false),
        ("https://0x7f.1/u", false),
        ("https://localhost/u", false),
        ("https://localhost./u", false),
        ("https://unsubscribe.localhost/u", false),
        ("https://printer.local/u", false),
        ("https://router.home.arpa/u", false),
        ("https://intranet/u", false),
        ("https://user:secret@list.example.com/u", false),
        ("https://user@list.example.com/u", false),
        ("https://list.example.com:8443/u", false),
    ])
    func allowsOnlyPublicLookingHTTPSNames(url: String, allowed: Bool) throws {
        #expect(UnsubscribeTarget.isAllowed(try #require(URL(string: url))) == allowed)
    }

    @Test(arguments: [
        "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.1", "127.0.0.1", "127.8.9.10",
        "169.254.10.20", "100.64.0.1", "100.127.255.254", "0.0.0.0", "0.1.2.3", "224.0.0.251", "239.255.255.250",
        "255.255.255.255", "192.0.2.1", "198.51.100.7", "203.0.113.9", "198.18.0.1",
        "::", "::1", "fe80::1", "febf::1", "fc00::1", "fd12:3456::1", "ff02::1", "ff05::1:3",
        "::ffff:192.168.1.1", "::ffff:127.0.0.1", "::ffff:c0a8:0101", "64:ff9b::a00:1", "2002:c0a8:101::1",
        "2001:db8::1", "::192.168.1.1", "not an address", "", "fe80::1%en0", "1.2.3", "256.1.1.1",
    ])
    func refusesNonPublicAddresses(address: String) {
        #expect(!UnsubscribeTarget.isPublic(address: address))
    }

    @Test(arguments: [
        "93.184.216.34", "8.8.8.8", "1.1.1.1", "100.128.0.1", "172.32.0.1", "192.169.0.1",
        "2606:4700:4700::1111", "2a00:1450:4001:80b::200e", "::ffff:8.8.8.8", "64:ff9b::808:808",
    ])
    func acceptsPublicAddresses(address: String) {
        #expect(UnsubscribeTarget.isPublic(address: address))
    }
}
