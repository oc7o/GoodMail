import Foundation
import Testing
@testable import MailPrivacy

struct OutgoingHTMLSanitizerTests {
    /// The hostile original of the editor spike (E14), plus entity-encoded scripts and oversized data images.
    static let hostile = """
        <html><head><title>T</title><style>body { color: red !important } p { font-size: 40px }</style>
        <script>alert(1)</script><base href="https://evil.example/"><meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel="stylesheet" href="https://evil.example/x.css"></head>
        <body onload="steal()" background="https://evil.example/bg.png">
        <!-- a comment with <b>tags</b> --><!--[if mso]><table><tr><td>MSO only</td></tr></table><![endif]-->
        <p style="color: #333; background: url(https://evil.example/t.png); font-weight: bold; position: fixed">Hi <B>there</B>,
        please see <a href="https://shop.example/deal?utm_source=mail&id=42" onclick="x()">our deal</a> and
        <a href="jav&#x09;ascript:alert(1)">this</a> and <a href="  JAVASCRIPT:alert(2)">that</a> and
        <a href="&#106;&#97;vascript:alert(3)">those</a> and <a href="java\u{0}script:alert(4)">these</a>.
        <p>Second para with &amp; entity &copy; and &unknown; and 3 &lt; 4 <i>unclosed italic
        <ul><li>one<li>two</ul>
        <img src="https://tracker.example/open.gif?u=me" width="1" height="1">
        <img src="https://news.us1.list-manage.com/track/open.php?u=1&amp;id=2" width="40" height="40">
        <img src="https://cdn.example/logo.png" alt="Logo" width="120" onerror="x()">
        <img src="cid:part1.abc@example" alt="Inline chart">
        <img src="javascript:alert(3)"><img src="data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=">
        <svg onload="alert(4)"><circle r="5"/></svg><svg/onload=alert(5)>
        <iframe src="https://evil.example/frame"></iframe>
        <form action="https://evil.example/post"><input name="pw" type="password"><button>Go</button></form>
        <object data="https://evil.example/x.swf"><embed src="https://evil.example/y.swf"></object>
        <table border="1" cellpadding="4"><tr><td style="width: 50%">cell 1<td>cell 2</table>
        <div style="font-family: Georgia; e\\78pression(alert(6))">escaped css</div>
        <div style="width: expression(alert(7)); color: red; behavior: url(x.htc)">dynamic css</div>
        <div style="background-image: u&#x72;l(https://evil.example/u.png)">entity css</div>
        <p>Last</p></p></p>
        </body></html>
        """

    static let forbidden = [
        "<script", "<style", "<iframe", "<form", "<input", "<svg", "<base", "<meta", "<link", "<object", "<embed",
        "onload", "onclick", "onerror", "javascript:", "url(", "expression", "behavior", "evil.example",
        "tracker.example", "list-manage", "utm_source", "position", "<title", "refresh", "image/svg",
    ]

    @Test func removesEverythingActiveOrRemote() {
        let result = OutgoingHTMLSanitizer.sanitize(Self.hostile)
        let html = result.html.lowercased()
        for pattern in Self.forbidden {
            #expect(!html.contains(pattern), "found \(pattern)")
        }
        #expect(result.html.contains("<a href=\"https://shop.example/deal?id=42\">our deal</a>"))
        #expect(result.html.contains("<a>this</a>"))
        #expect(result.html.contains("<a>that</a>"))
        #expect(result.html.contains("<a>those</a>"))
        #expect(result.html.contains("<a>these</a>"))
        #expect(result.html.contains("<img src=\"https://cdn.example/logo.png\" alt=\"Logo\" width=\"120\">"))
        #expect(result.html.contains("<img src=\"cid:part1.abc@example\" alt=\"Inline chart\">"))
        #expect(result.html.contains("<p style=\"color: #333; font-weight: bold\">"))
        #expect(result.html.contains("<ul><li>one</li><li>two</li></ul>"))
        #expect(result.html.contains("<td style=\"width: 50%\">cell 1</td><td>cell 2</td>"))
        #expect(result.html.contains("<div style=\"color: red\">dynamic css</div>"))
        #expect(result.html.contains("<div>entity css</div>"))
        #expect(result.html.contains("Second para with &amp; entity © and &amp;unknown; and 3 &lt; 4"))
        #expect(result.contentIDs == ["part1.abc@example"])
        #expect(result.removedTrackers == 2)
        #expect(result.removedRemoteImages == 0)
    }

    @Test func plainTextRendering() {
        let text = OutgoingHTMLSanitizer.sanitize(Self.hostile).text
        #expect(text.hasPrefix("Hi there, please see our deal <https://shop.example/deal?id=42> and this and that"))
        #expect(text.contains("\n• one\n• two\n"))
        #expect(text.contains("[Logo] [Inline chart]"))
        #expect(text.contains("\tcell 1\tcell 2"))
        #expect(text.hasSuffix("Last"))
        #expect(!text.contains("MSO only"))
        #expect(!text.contains("alert"))
    }

    @Test func everyTruncatedPrefixIsBalancedAndSafe() throws {
        let tracked = try ["b", "i", "p", "div", "ul", "li", "table", "tr", "td", "a", "span"].map { name in
            (name: name, open: try Regex("<\(name)[ >]"), close: try Regex("</\(name)>"))
        }
        let characters = Array(Self.hostile)
        var failures: [String] = []
        for cut in 0...characters.count {
            let html = OutgoingHTMLSanitizer.sanitize(String(characters[..<cut])).html
            for tag in tracked where html.matches(of: tag.open).count != html.matches(of: tag.close).count {
                failures.append("<\(tag.name)> after cutting at \(cut)")
            }
            if html.lowercased().contains("<script") || html.lowercased().contains("javascript:") {
                failures.append("active content after cutting at \(cut)")
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test func sanitizingTwiceChangesNothing() {
        let once = OutgoingHTMLSanitizer.sanitize(Self.hostile)
        let twice = OutgoingHTMLSanitizer.sanitize(once.html)
        #expect(twice.html == once.html)
        #expect(twice.text == once.text)
    }

    @Test func dataImagesOverTheLimitAreDropped() {
        let small = "data:image/png;base64," + String(repeating: "A", count: 400)
        let large = "data:image/png;base64," + String(repeating: "A", count: 400_000)
        let html = "<img src=\"\(small)\"><img src=\"\(large)\"><img src=\"data:text/html;base64,PGI+\">"
        let result = OutgoingHTMLSanitizer.sanitize(html)
        #expect(result.html == "<img src=\"\(small)\">")

        let strict = OutgoingHTMLSanitizer.sanitize(html, options: .init(maxDataImageBytes: 100))
        #expect(strict.html.isEmpty)
    }

    @Test func remoteImagesCanBeRemoved() {
        let html = "<img src=\"https://cdn.example/a.png\" width=\"20\"><img src=\"cid:x@y\"><img src=\"//cdn.example/b.png\">"
        let kept = OutgoingHTMLSanitizer.sanitize(html)
        #expect(kept.html.contains("https://cdn.example/a.png"))
        #expect(kept.html.contains("https://cdn.example/b.png"))
        let removed = OutgoingHTMLSanitizer.sanitize(html, options: .init(remoteImages: .remove))
        #expect(removed.html == "<img src=\"cid:x@y\">")
        #expect(removed.removedRemoteImages == 2)
    }

    @Test func linksAreCleanedOnlyWhenAsked() {
        let html = "<a href=\"https://shop.example/a?utm_campaign=x&amp;id=1\">deal</a>"
        #expect(OutgoingHTMLSanitizer.sanitize(html).html == "<a href=\"https://shop.example/a?id=1\">deal</a>")
        let kept = OutgoingHTMLSanitizer.sanitize(html, options: .init(cleansLinks: false))
        #expect(kept.html == "<a href=\"https://shop.example/a?utm_campaign=x&amp;id=1\">deal</a>")
    }

    @Test func onlyAllowedClassesSurvive() {
        let html = "<div class=\"signature x-evil\" id=\"sig\" data-goodmail=\"1\">Alex</div><p class=\"MsoNormal\">Hi</p>"
        #expect(OutgoingHTMLSanitizer.sanitize(html).html == "<div>Alex</div><p>Hi</p>")
        let kept = OutgoingHTMLSanitizer.sanitize(html, options: .init(allowedClasses: ["signature"]))
        #expect(kept.html == "<div class=\"signature\">Alex</div><p>Hi</p>")
    }

    @Test func entitiesAndQuotesAreReEscaped() {
        let html = "<a title='a \"quote\" &amp; <tag>' href=\"mailto:a@b.example\">x &lt;y&gt; \"z\"</a>"
        let result = OutgoingHTMLSanitizer.sanitize(html).html
        #expect(result == "<a title=\"a &quot;quote&quot; &amp; &lt;tag&gt;\" href=\"mailto:a@b.example\">x &lt;y&gt; \"z\"</a>")
    }

    /// Hostile nesting must neither hang the app nor produce output nested without bound.
    @Test func pathologicalMarkupStaysCheap() {
        let deep = String(repeating: "<b><span>", count: 20_000) + String(repeating: "<a href=\"https://x.example\">x", count: 5_000)
            + String(repeating: "<li>y", count: 5_000) + String(repeating: "</i>", count: 5_000)
        let clock = ContinuousClock()
        var result = OutgoingHTMLSanitizer.Result(html: "", contentIDs: [], removedTrackers: 0, removedRemoteImages: 0, text: "")
        let elapsed = clock.measure { result = OutgoingHTMLSanitizer.sanitize(deep) }
        #expect(elapsed < .seconds(5))
        #expect(result.html.components(separatedBy: "<span>").count - 1 <= OutgoingHTMLSanitizer.maximumDepth)
        #expect(result.html.components(separatedBy: "<b>").count == result.html.components(separatedBy: "</b>").count)

        let unclosed = String(repeating: "<svg>a<embed src=\"https://x.example\">", count: 20_000) + "<p>visible</p>"
        let unclosedElapsed = clock.measure { result = OutgoingHTMLSanitizer.sanitize(unclosed) }
        #expect(unclosedElapsed < .seconds(5))
        #expect(!result.html.contains("svg") && !result.html.contains("embed"))
    }

    /// Hostile markup must cost about what as much ordinary markup costs: deep nesting, end tags without a start,
    /// and "<" or "&" that start nothing.
    @Test(.serialized, arguments: [
        ("<li>", String(repeating: "<b>", count: 256)), ("</i>", String(repeating: "<b>", count: 256)),
        ("<dt>", String(repeating: "<b>", count: 250)), ("<a>", String(repeating: "<b>", count: 256)),
    ])
    func hostileNestingCostsWhatFlatMarkupCosts(tag: String, prefix: String) {
        let flat = String(repeating: tag, count: 100_000)
        let clock = ContinuousClock()
        let flatTime = clock.measure { _ = OutgoingHTMLSanitizer.sanitize(flat) }
        let hostileTime = clock.measure { _ = OutgoingHTMLSanitizer.sanitize(prefix + flat) }
        #expect(hostileTime < flatTime * 3 + .milliseconds(250), "\(hostileTime) against \(flatTime)")
    }

    @Test(.serialized, arguments: ["< ", "& ", "&# ", "&amp "])
    func strayMarkupCharactersCostWhatTextCosts(fragment: String) {
        let size = 1_000_000
        let clock = ContinuousClock()
        let textTime = clock.measure { _ = OutgoingHTMLSanitizer.sanitize(String(repeating: "a ", count: size / 2)) }
        let stray = String(repeating: fragment, count: size / fragment.utf8.count)
        let strayTime = clock.measure { _ = OutgoingHTMLSanitizer.sanitize(stray) }
        #expect(strayTime < textTime * 3 + .milliseconds(250), "\(strayTime) against \(textTime)")
    }

    /// Quoted mail often comes from PHP's htmlentities() or Word: every named reference a browser knows, and
    /// numeric references in 128–159 as the Windows-1252 characters they meant.
    @Test func characterReferencesReadAsInABrowser() {
        let result = OutgoingHTMLSanitizer.sanitize("<p>&Eacute;t&eacute; &agrave; l&rsquo;h&ocirc;tel &rarr; it&#146;s &hearts;</p>")
        #expect(result.html == "<p>Été à l’hôtel → it’s ♥</p>")
        #expect(result.text == "Été à l’hôtel → it’s ♥")
        #expect(OutgoingHTMLSanitizer.sanitize("&NotEqualTilde; &AMP; &frac12; &sect;3 &Ccedil;a").text == "\u{2242}\u{0338} & ½ §3 Ça")
    }

    @Test func referencesWithoutSemicolonFollowHTMLsRules() {
        // Old names work without ";" in text, but not where a URL parameter would be taken for one.
        #expect(OutgoingHTMLSanitizer.sanitize("&copy 2026 &amp co &notit; AT&T &unknown;").text == "© 2026 & co ¬it; AT&T &unknown;")
        let link = OutgoingHTMLSanitizer.sanitize("<a href=\"https://x.example/?a=1&copy=2&amp;b=3&not\">x</a>", options: .init(cleansLinks: false))
        #expect(link.html == "<a href=\"https://x.example/?a=1&amp;copy=2&amp;b=3%C2%AC\">x</a>")
    }

    @Test func numericReferencesFollowHTMLsErrorHandling() {
        let text = OutgoingHTMLSanitizer.sanitize("&#0;|&#xD800;|&#x110000;|&#99999999999;|&#128;|&#x81;|&#39|&#x;|&#;|&#x41;").text
        #expect(text == "\u{FFFD}|\u{FFFD}|\u{FFFD}|\u{FFFD}|€|\u{81}|'|&#x;|&#;|A")
    }

    @Test(arguments: [
        // Removed content that showed.
        ("<div>a<svg><text>label</text></svg>b</div>", [OutgoingHTMLSanitizer.Loss.content]),
        ("<math><mi>x</mi></math>", [.content]), ("<button>Accept</button>", [.content]),
        ("<select><option>1</option></select>", [.content]), ("<textarea>x</textarea>", [.content]),
        ("<iframe src=\"https://x.example\"></iframe>", [.content]), ("<video>fallback</video>", [.content]),
        ("<noscript>shown</noscript>", [.content]), ("<input value=\"x\">", [.content]),
        ("<img src=\"javascript:x()\">", [.image]), ("<img src=\"https://t.example/p.gif\" width=\"1\" height=\"1\">", [.image]),
        ("<td background=\"https://x.example/bg.png\">x</td>", [.image]),
        // Link targets and styles.
        ("<a href=\"sms:+15551234\">me</a>", [.content]), ("<a href=\"ftp://f.example/r.pdf\">r</a>", [.content]),
        ("<a href=\"#details\">d</a>", [.content]), ("<span style=\"position: absolute; color: red\">x</span>", [.content]),
        ("<div style=\"background-image: url(https://x.example/a.png)\">x</div>", [.content]),
        ("<font color=\"rgb(255, 0, 0)\">x</font>", [.content]), ("<label style=\"color: red\">x</label>", [.content]),
        ("<body style=\"font-family: Georgia\">x</body>", [.content]), ("<body bgcolor=\"#ffeecc\">x</body>", [.content]),
        // Nothing that showed.
        ("<script>x()</script><style></style><title>T</title><template>t</template><input type=\"hidden\">", []),
        ("<a href=\"https://x.example\">x</a><a href=\"\">y</a><a name=\"top\">z</a>", []),
        ("<span style=\"-webkit-text-size-adjust: none; mso-line-height-rule: exactly; cursor: pointer\">x</span>", []),
        ("<body style=\"overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;\">x</body>", []),
        ("<body text=\"#000000\" bgcolor=\"#FFFFFF\" dir=\"auto\"><o:p></o:p>x</body>", []),
    ])
    func reportsWhatItRemoves(html: String, losses: [OutgoingHTMLSanitizer.Loss]) {
        #expect(OutgoingHTMLSanitizer.sanitize(html).losses(through: .max) == Set(losses))
    }

    @Test func lossesAreFoundWhereTheyHappened() throws {
        let html = "<div>a</div><svg></svg><div style=\"position: fixed\">b</div><img src=\"javascript:x\">"
        let result = OutgoingHTMLSanitizer.sanitize(html)
        #expect(result.html == "<div>a</div><div>b</div>")
        #expect(result.firstLoss[.content] == "<div>a</div>".utf8.count)
        #expect(result.firstLoss[.image] == result.html.utf8.count)
        #expect(result.losses(through: "<div>a</div>".utf8.count - 1).isEmpty)
    }

    /// Fastmail's web client puts `p.MsoNormal{margin:0}` into everything it writes; it only matters for Outlook's
    /// paragraphs.
    @Test func styleSheetsCountWhereTheirRulesApply() throws {
        let fastmail = "<style type=\"text/css\">p.MsoNormal,p.MsoNoSpacing{margin:0}</style>"
        #expect(OutgoingHTMLSanitizer.sanitize(fastmail + "<div>Hi</div>").firstLoss.isEmpty)

        let reply = fastmail + "<div>Hi</div><blockquote type=\"cite\"><p class=\"MsoNormal\">Outlook</p></blockquote>"
        let result = OutgoingHTMLSanitizer.sanitize(reply)
        let quote = try #require(result.html.range(of: "<p>"))
        #expect(result.firstLoss[.content] == result.html.utf8.distance(from: result.html.startIndex, to: quote.lowerBound) + 1)

        for css in [
            "body { font-family: Calibri }", "* { color: navy }", "div { margin-left: 2em }", ".x { color: red }",
            "#y { color: red }", "div.x > span { font-weight: bold }", "@media screen { .x { color: red } }",
            "<!-- .x { color: red } -->", "a:link, .x { color: red }",
        ] {
            let html = "<style>\(css)</style><div class=\"x\" id=\"y\"><span>text</span></div>"
            #expect(OutgoingHTMLSanitizer.sanitize(html).firstLoss[.content] != nil, "\(css)")
        }
        for css in [
            ".absent { color: red }", "#absent { color: red }", "span.x { color: red }", "div:hover { color: red }",
            "@font-face { font-family: X; src: url(x.woff) }", "@page { margin: 1cm }", ".x { }", "/* .x { color: red } */",
            "@import url(https://x.example/a.css);",
        ] {
            let html = "<style>\(css)</style><div class=\"x\" id=\"y\"><span>text</span></div>"
            #expect(OutgoingHTMLSanitizer.sanitize(html).firstLoss.isEmpty, "\(css)")
        }
    }

    @Test func hiddenContentStaysHidden() {
        #expect(OutgoingHTMLSanitizer.sanitize("<div hidden>secret</div><p style=\"color: red\" hidden>x</p>").html
                == "<div style=\"display: none\">secret</div><p style=\"color: red; display: none\">x</p>")
        #expect(OutgoingHTMLSanitizer.sanitize("<span style=\"visibility: hidden; opacity: 0; overflow: hidden\">p</span>").html
                == "<span style=\"visibility: hidden; opacity: 0; overflow: hidden\">p</span>")
    }

    @Test func blockElementsOutsideTheAllowlistStayBlocks() {
        let html = "<section>one</section><article><header>two</header><footer>three</footer></article><menu><li>four</li></menu>"
        let result = OutgoingHTMLSanitizer.sanitize(html)
        #expect(result.html == "<div>one</div><div><div>two</div><div>three</div></div><ul><li>four</li></ul>")
        #expect(result.text == "one\ntwo\nthree\n• four")
    }

    @Test func implicitClosingFollowsHTMLParsingRules() {
        let html = "<p>one<p>two<div>three</div><a href=\"https://a.example\">a<a href=\"https://b.example\">b</a>"
        #expect(OutgoingHTMLSanitizer.sanitize(html).html
                == "<p>one</p><p>two</p><div>three</div><a href=\"https://a.example\">a</a><a href=\"https://b.example\">b</a>")
    }
}
