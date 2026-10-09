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

    @Test func implicitClosingFollowsHTMLParsingRules() {
        let html = "<p>one<p>two<div>three</div><a href=\"https://a.example\">a<a href=\"https://b.example\">b</a>"
        #expect(OutgoingHTMLSanitizer.sanitize(html).html
                == "<p>one</p><p>two</p><div>three</div><a href=\"https://a.example\">a</a><a href=\"https://b.example\">b</a>")
    }
}
