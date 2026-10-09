import Foundation
import SwiftUI
import Testing
@testable import MailCompose

struct HTMLReaderTests {
    static var roundTripBodies: [AttributedString] {
        var mixed = AttributedString("שלום\ncentered\n• bold item\n1. first\n2. second\n7. seventh\nend\u{2028}line\u{2028}")
        mixed[mixed.range(of: "שלום")!].writingDirection = .rightToLeft
        mixed[mixed.range(of: "centered")!].alignment = .center
        mixed[mixed.range(of: "bold")!].font = MailFontStyle(isBold: true, isItalic: true, size: .large).font
        var colours = AttributedString("red orange green blue purple gray mono-small")
        for entry in MailPalette.colors {
            colours[colours.range(of: entry.name.lowercased())!].foregroundColor = entry.color
        }
        colours[colours.range(of: "mono-small")!].font = MailFontStyle(isMonospaced: true, size: .small).font
        var link = AttributedString("a link and mail")
        link[link.range(of: "link")!].link = URL(string: "https://example.com/a?utm_source=x&b=%20c#frag")
        link[link.range(of: "mail")!].link = URL(string: "mailto:maya@lindqvist.example?subject=Hi")
        return [
            Fixture.formattedBody(), mixed, colours, link,
            AttributedString(""), AttributedString("\n\n"), AttributedString("  spaced   out  \n\ttab\t"),
            AttributedString("<html> & \"quotes\" 'too'"), AttributedString("10\u{2009}km\u{3000}wide \u{2003}em"),
            AttributedString(" \n"),
        ]
    }

    @Test(arguments: roundTripBodies)
    func writerReaderWriterIsStable(body: AttributedString) {
        let first = MailHTMLWriter.write(body)
        let read = MailBodyHTMLReader.read(first.html)
        #expect(read.dropped.isEmpty)
        let second = MailHTMLWriter.write(read.text)
        #expect(second == first)
    }

    @Test func readsTheEditorsOwnStructure() {
        let html = "<div>Hi,</div><div><br></div><ul><li>one</li><li><br></li></ul><div>&nbsp;two&nbsp;</div>"
        let result = MailBodyHTMLReader.read(html)
        #expect(String(result.text.characters) == "Hi,\n\n• one\n• \n two ")
        #expect(result.dropped.isEmpty)
    }

    @Test func readsAFastmailWebDraft() {
        let html = """
            <div>Hi,<br></div><div><br></div><div>this is a <b>draft</b> from the <i>web</i> client with \
            <span style="color:rgb(255, 0, 0);">red</span> and <span style="font-size:large;">large</span> text.<br></div>\
            <ul><li>one<br></li><li>two<br></li></ul><div><a href="https://www.fastmail.com/">a link</a><br></div>\
            <div id="sig123"><div class="signature">-- <br></div><div class="signature">Max<br></div></div>
            """
        let result = MailBodyHTMLReader.read(html)
        // A space right before a line break doesn't render, so the delimiter reads as "--".
        #expect(String(result.text.characters)
                == "Hi,\n\nthis is a draft from the web client with red and large text.\n• one\n• two\na link\n--\nMax")
        #expect(result.dropped == [.colors, .sizes])
        #expect(MailHTMLWriter.write(result.text).html == """
            <div>Hi,</div><div><br></div><div>this is a <b>draft</b> from the <i>web</i> client with red and \
            <span style="font-size: 130%">large</span> text.</div><ul><li>one</li><li>two</li></ul>\
            <div><a href="https://www.fastmail.com/">a link</a></div><div>--</div><div>Max</div>
            """)
    }

    @Test(arguments: [
        ("<div>Logo <img src=\"cid:logo@x\"> and <img src=\"https://cdn.example/a.png\"></div>", [MailBodyHTMLReader.Feature.images]),
        ("<table><tr><td>a</td><td>b</td></tr></table>", [.tables]),
        ("<span style=\"font-family: Georgia, serif\">x</span>", [.fonts]),
        ("<font face=\"Arial\">x</font>", [.fonts]),
        ("<span style=\"color: #123456\">x</span>", [.colors]),
        ("<div style=\"background-color: yellow\">x</div>", [.colors]),
        ("<span style=\"font-size: 40px\">x</span>", [.sizes]),
        ("<h1>Title</h1>", [.sizes]),
        ("<ul><li>a<ul><li>b</li></ul></li></ul>", [.nestedLists]),
        ("<blockquote>quoted</blockquote>", [.quotes]),
        ("<pre>code\n  indented</pre>", [.preformatted]),
        ("<p>x<sup>2</sup></p>", [.other]),
        ("<div style=\"font-family: Menlo, monospace; color: #0040DD; font-size: 80%\">x</div>", []),
    ])
    func reportsWhatItSimplifies(html: String, features: [MailBodyHTMLReader.Feature]) {
        #expect(MailBodyHTMLReader.read(html).dropped == Set(features))
    }

    @Test func tablesBecomeTabSeparatedLines() {
        let result = MailBodyHTMLReader.read("<table><tr><td>a</td><td>b</td></tr><tr><td>c </td><td>d</td></tr></table>")
        #expect(String(result.text.characters) == "a\tb\nc \td")
    }

    @Test func paragraphMarginsReadAsEmptyLines() {
        let result = MailBodyHTMLReader.read("<p>first</p><p>second</p>\n<p>third</p><ul><li><p>item</p></li></ul>")
        #expect(String(result.text.characters) == "first\n\nsecond\n\nthird\n\n• item")
    }

    @Test func lineBreaksInsideABlock() {
        let result = MailBodyHTMLReader.read("<div>one<br>two<br><br>three<br></div><div><br></div><div>four</div>")
        #expect(String(result.text.characters) == "one\u{2028}two\u{2028}\u{2028}three\n\nfour")
    }

    @Test func hiddenContentStaysOut() {
        let result = MailBodyHTMLReader.read("<div>shown<span style=\"display: none\">hidden</span></div>")
        #expect(String(result.text.characters) == "shown")
        #expect(result.dropped == [.other])
    }

    @Test func untrustedMarkupIsSanitizedFirst() {
        let result = MailBodyHTMLReader.read("<div onclick=\"x()\">a<script>alert(1)</script><a href=\"javascript:x()\">b</a></div>")
        #expect(String(result.text.characters) == "ab")
        #expect(result.text.runs.allSatisfy { $0.link == nil })
    }
}
