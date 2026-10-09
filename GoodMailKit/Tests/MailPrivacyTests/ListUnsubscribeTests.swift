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
    static let results = """
        mx.messagingengine.com; arc=none (no signatures found); \
        dkim=pass (2048-bit rsa key sha256) header.d=fjord-outdoor.example header.i=@fjord-outdoor.example \
        header.b=AbCdEfGh header.a=rsa-sha256 header.s=fm1 x-bits=2048; \
        dmarc=pass policy.published-domain-policy=none; spf=pass smtp.mailfrom=bounce@fjord-outdoor.example
        """

    struct Headers {
        var listUnsubscribe = [[ListUnsubscribeTests.mailtoURL, ListUnsubscribeTests.oneClickURL]]
        var listUnsubscribePost = ["List-Unsubscribe=One-Click"]
        var dkimSignatures = [ListUnsubscribeTests.signature]
        var authenticationResults = [ListUnsubscribeTests.results]
        var trusted: Set<String> = ["mx.messagingengine.com"]

        var methods: [ListUnsubscribe.Method] {
            ListUnsubscribe.methods(
                listUnsubscribe: listUnsubscribe, listUnsubscribePost: listUnsubscribePost,
                dkimSignatures: dkimSignatures, authenticationResults: authenticationResults,
                isTrustedAuthServID: trusted.contains)
        }

        var offersOneClick: Bool {
            methods.contains { if case .oneClick = $0 { true } else { false } }
        }
    }

    static let mailto = ListUnsubscribe.Method.mailto(MailtoLink(URL(string: mailtoURL)!)!)
    static let web = ListUnsubscribe.Method.web(URL(string: oneClickURL)!)

    @Test func oneClickFirstWhenEverythingChecksOut() {
        #expect(Headers().methods == [.oneClick(URL(string: Self.oneClickURL)!), Self.mailto, Self.web])
    }

    @Test func noOneClickWhileNoAuthServIDIsTrusted() {
        var headers = Headers()
        headers.trusted = []
        #expect(headers.methods == [Self.mailto, Self.web])
    }

    @Test func noOneClickWithoutDKIM() {
        var headers = Headers()
        headers.dkimSignatures = []
        #expect(!headers.offersOneClick)
    }

    @Test func noOneClickWhenTheSignatureDoesNotCoverThePostHeader() {
        var headers = Headers()
        headers.dkimSignatures = [Self.signature.replacingOccurrences(of: ":list-unsubscribe-post", with: "")]
        #expect(!headers.offersOneClick)
    }

    @Test func onlyTheTopmostAuthenticationResultsCount() {
        var headers = Headers()
        headers.authenticationResults = [
            "attacker.example; dkim=pass header.d=fjord-outdoor.example header.b=AbCdEfGh", Self.results,
        ]
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
        headers.authenticationResults = [Self.results.replacingOccurrences(of: "dkim=pass", with: "dkim=fail")]
        #expect(!headers.offersOneClick)
    }

    @Test(arguments: ["AbCdEfG", "AbCdEfGX", "abcdefgh"])
    func signaturePrefixMustBeLongAndMatch(prefix: String) {
        var headers = Headers()
        headers.authenticationResults = [Self.results.replacingOccurrences(of: "header.b=AbCdEfGh", with: "header.b=\(prefix)")]
        #expect(!headers.offersOneClick)
    }

    @Test func aLongerMatchingPrefixWorks() {
        var headers = Headers()
        headers.authenticationResults = [
            Self.results.replacingOccurrences(of: "header.b=AbCdEfGh", with: "header.b=AbCdEfGhIjKlMnOp"),
        ]
        #expect(headers.offersOneClick)
    }

    @Test func signingDomainMustMatch() {
        var headers = Headers()
        headers.authenticationResults = [Self.results.replacingOccurrences(
            of: "header.d=fjord-outdoor.example", with: "header.d=mailer.example")]
        #expect(!headers.offersOneClick)
    }

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
    }

    @Test func parsesDKIMSignatures() throws {
        let signature = try #require(DKIMSignature(Self.signature))
        #expect(signature.domain == "fjord-outdoor.example")
        #expect(signature.signedHeaders == ["from", "to", "subject", "list-unsubscribe", "list-unsubscribe-post"])
        #expect(signature.signature == "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdEfGhIjKlMnOpQrStUvWxyz0123456789==")
        #expect(DKIMSignature("v=1; d=example.com") == nil)
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
