import Foundation
import MailPrivacy
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
        var partlyBold = AttributedString("Visit Google today")
        partlyBold[partlyBold.range(of: "Google")!].link = URL(string: "https://google.com")
        partlyBold[partlyBold.range(of: "Go")!].font = MailFontStyle(isBold: true).font
        // A line break at the end of formatted text, and one at the end of a list item.
        var softBreaks = AttributedString("end\u{2028}\n• item\u{2028}")
        softBreaks[softBreaks.range(of: "end\u{2028}")!].font = MailFontStyle(isBold: true).font
        return [
            Fixture.formattedBody(), mixed, colours, link, partlyBold, softBreaks,
            AttributedString(""), AttributedString("\n\n"), AttributedString("  spaced   out  \n\ttab\t"),
            AttributedString("<html> & \"quotes\" 'too'"), AttributedString("10\u{2009}km\u{3000}wide \u{2003}em"),
            AttributedString(" \n"), AttributedString("Bonjour\u{00A0}! 10\u{00A0}km\u{00A0}\u{2028}x\u{00A0} y"),
        ]
    }

    /// Typed no-break spaces stay what they are, except where the writer itself writes one for a space: at either
    /// end of a line and after a space. There the two look the same, so they are read as spaces and written the same.
    @Test func noBreakSpacesAreKept() {
        let body = MailHTMLWriter.write(AttributedString("Bonjour\u{00A0}! 10\u{00A0}km  apart"))
        #expect(body.html == "<div>Bonjour&nbsp;! 10&nbsp;km &nbsp;apart</div>")
        #expect(String(MailBodyHTMLReader.read(body.html).text.characters) == "Bonjour\u{00A0}! 10\u{00A0}km  apart")

        let edges = MailHTMLWriter.write(AttributedString("\u{00A0}lead, trail\u{00A0}"))
        let read = MailBodyHTMLReader.read(edges.html)
        #expect(String(read.text.characters) == " lead, trail ")
        #expect(MailHTMLWriter.write(read.text).html == edges.html)
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
        // List markers the editor's "1." and "•" can't show.
        ("<ol type=\"a\"><li>x</li></ol>", [.other]), ("<ul type=\"square\"><li>x</li></ul>", [.other]),
        ("<ol reversed><li>x</li></ol>", [.other]), ("<ol style=\"list-style-type: lower-roman\"><li>x</li></ol>", [.other]),
        ("<ul style=\"list-style: none\"><li>x</li></ul>", [.other]),
        ("<ol type=\"1\" style=\"list-style-type: decimal\"><li>x</li></ol><ul type=\"disc\"><li>y</li></ul>", []),
        // Layout and visibility the editor has no way to hold.
        ("<div style=\"margin-left: 40px\">x</div>", [.other]), ("<div style=\"padding: 0 0 0 2em\">x</div>", [.other]),
        ("<p style=\"text-indent: 2em\">x</p>", [.other]), ("<span style=\"visibility: hidden\">x</span>", [.other]),
        ("<span style=\"opacity: 0.5\">x</span>", [.other]), ("<span style=\"color: transparent\">x</span>", [.colors]),
        ("<div style=\"float: right\">x</div>", [.other]), ("<span style=\"display: block\">x</span>", [.other]),
        ("<div style=\"border: 1px solid #ccc\">x</div>", [.other]), ("<div style=\"overflow: hidden\">x</div>", [.other]),
        ("<div style=\"margin: 0; padding: 0px; text-indent: 0; border: none; display: block\">x</div>", []),
        // What the sanitizer removes.
        ("<div><a href=\"sms:+15551234\">me</a></div>", [.other]), ("<div>a<svg><text>b</text></svg></div>", [.other]),
        ("<div>Press <button>OK</button></div>", [.other]), ("<div>x <math><mi>y</mi></math></div>", [.other]),
        ("<style>.big { font-size: 24pt }</style><div class=\"big\">x</div>", [.other]),
        ("<div><img src=\"javascript:x()\">x</div>", [.images]),
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
        let zero = MailBodyHTMLReader.read("<p style=\"margin: 0\">one</p><p style=\"margin:0px\">two</p><p style=\"margin-top: 0\">three</p><div>four</div>")
        #expect(String(zero.text.characters) == "one\ntwo\nthree\n\nfour")
        #expect(zero.dropped.isEmpty)
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

    @Test func deepNestingIsFlattened() {
        let depth = 20_000
        let html = String(repeating: "<div><b>", count: depth) + "deep" + String(repeating: "</b></div>", count: depth)
            + "<div>after</div>"
        let result = MailBodyHTMLReader.read(html)
        #expect(String(result.text.characters) == "deep\nafter")
        #expect(result.dropped == [.other]) // the formatting of what was flattened is lost
        #expect(HTMLNode.parse("<i>a<b>b</b></i><br>").count == 2)

        // Deeper than the tree keeps, though not deeper than the sanitizer does.
        let nested = String(repeating: "<div><b>", count: 50) + "deep" + String(repeating: "</b></div>", count: 50)
        #expect(OutgoingHTMLSanitizer.sanitize(nested).firstLoss.isEmpty)
        #expect(MailBodyHTMLReader.read(nested).dropped == [.other])
        #expect(MailBodyHTMLReader.read(String(repeating: "<div><b>", count: 30) + "x").dropped.isEmpty)
    }

    @Test func untrustedMarkupIsSanitizedFirst() {
        let result = MailBodyHTMLReader.read("<div onclick=\"x()\">a<script>alert(1)</script><a href=\"javascript:x()\">b</a></div>")
        #expect(String(result.text.characters) == "ab")
        #expect(result.text.runs.allSatisfy { $0.link == nil })
    }
}
