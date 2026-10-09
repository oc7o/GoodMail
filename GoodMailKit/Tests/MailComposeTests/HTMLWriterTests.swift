import Foundation
import SwiftUI
import Testing
@testable import MailCompose

struct HTMLWriterTests {
    @Test func writesFormattingListsLinksAndSpaces() {
        let body = MailHTMLWriter.write(Fixture.formattedBody())
        #expect(body.html == """
            <div>Hello Anna,</div><div><br></div>\
            <div><b>thanks</b> for the <i><u>notes</u></i>. <span style="color: #d70015">Three things</span>:</div>\
            <ul><li>first point</li><li>second point</li></ul><div><br></div>\
            <div>See <a href="https://example.com/doc?utm_source=x&amp;page=2">https://example.com/doc</a> for \
            <span style="font-size: 130%"><s>details</s></span>. &nbsp;Two &nbsp;spaces.</div>\
            <div><code>Cheers</code></div>
            """)
        #expect(body.text == """
            Hello Anna,

            thanks for the notes. Three things:
            • first point
            • second point

            See https://example.com/doc <https://example.com/doc?utm_source=x&page=2> for details.  Two  spaces.
            Cheers
            """)
    }

    /// Links the user puts in are sent exactly as entered, tracking parameters included.
    @Test func pastedLinksKeepTheirTrackingParameters() {
        var text = AttributedString("Use my referral link")
        text.link = URL(string: "https://shop.example/r?utm_source=friend&utm_medium=mail&fbclid=abc&ref=alex")
        let body = MailHTMLWriter.write(text)
        #expect(body.html == """
            <div><a href="https://shop.example/r?utm_source=friend&amp;utm_medium=mail&amp;fbclid=abc&amp;ref=alex">\
            Use my referral link</a></div>
            """)
        #expect(body.text == "Use my referral link <https://shop.example/r?utm_source=friend&utm_medium=mail&fbclid=abc&ref=alex>")
        let back = MailBodyHTMLReader.read(body.html).text
        #expect(back.runs.first?.link?.absoluteString
                == "https://shop.example/r?utm_source=friend&utm_medium=mail&fbclid=abc&ref=alex")
    }

    @Test func allFontTraitsAndPaletteColours() {
        var text = AttributedString("bold italic under strike code huge small green")
        for (word, change) in [
            ("bold", { (style: inout MailFontStyle) in style.isBold = true }),
            ("italic", { $0.isItalic = true }), ("code", { $0.isMonospaced = true }),
            ("huge", { $0.size = .huge }), ("small", { $0.size = .small }),
        ] as [(String, (inout MailFontStyle) -> Void)] {
            var selection = Fixture.selection(of: word, in: text)
            text.updateFont(change, selection: &selection, in: Fixture.context)
        }
        var selection = Fixture.selection(of: "under", in: text)
        text.setUnderline(true, selection: &selection)
        selection = Fixture.selection(of: "strike", in: text)
        text.setStrikethrough(true, selection: &selection)
        selection = Fixture.selection(of: "green", in: text)
        text.setColor(MailPalette.colors.first { $0.name == "Green" }, selection: &selection)
        #expect(MailHTMLWriter.write(text).html == """
            <div><b>bold</b> <i>italic</i> <u>under</u> <s>strike</s> <code>code</code> \
            <span style="font-size: 170%">huge</span> <span style="font-size: 80%">small</span> \
            <span style="color: #248a3d">green</span></div>
            """)
    }

    @Test func numberedListsKeepTheirNumbers() {
        let body = MailHTMLWriter.write(AttributedString("Steps:\n1. one\n2. two\nthen\n3. three\n9. four\n• dot"))
        #expect(body.html == """
            <div>Steps:</div><ol><li>one</li><li>two</li></ol><div>then</div>\
            <ol start="3"><li>three</li><li>four</li></ol><ul><li>dot</li></ul>
            """)
        #expect(body.text == "Steps:\n1. one\n2. two\nthen\n3. three\n4. four\n• dot")
    }

    @Test func emptyParagraphsAndEdgeSpaces() {
        let body = MailHTMLWriter.write(AttributedString(" lead\n\ntrail \n   \n• \n"))
        #expect(body.html == """
            <div>&nbsp;lead</div><div><br></div><div>trail&nbsp;</div><div>&nbsp; &nbsp;</div>\
            <ul><li><br></li></ul><div><br></div>
            """)
        #expect(MailHTMLWriter.write(AttributedString()).html == "<div><br></div>")
    }

    @Test func paragraphDirectionAndAlignment() {
        var text = AttributedString("שלום עולם\ncentered\nright")
        let hebrew = text.range(of: "שלום עולם")!
        text[hebrew].writingDirection = .rightToLeft
        text[hebrew].alignment = .right
        text[text.range(of: "centered")!].alignment = .center
        text[text.range(of: "right")!].alignment = .right
        #expect(MailHTMLWriter.write(text).html == """
            <div dir="rtl" style="text-align: right">שלום עולם</div><div style="text-align: center">centered</div>\
            <div style="text-align: right">right</div>
            """)
    }

    @Test func escapingTabsAndLineBreaks() {
        let body = MailHTMLWriter.write(AttributedString("a < b & c > d\tTab\u{2028}soft\nend\u{2028}"))
        #expect(body.html == """
            <div>a &lt; b &amp; c &gt; d<span style="white-space: pre">\t</span>Tab<br>soft</div><div>end<br><br></div>
            """)
        #expect(body.text == "a < b & c > d\tTab\nsoft\nend\n")
    }

    @Test func textAlternativeShowsHiddenLinkTargets() {
        var text = AttributedString("Write to alex@fastmail.com or our team, see https://a.example")
        text[text.range(of: "alex@fastmail.com")!].link = URL(string: "mailto:alex@fastmail.com")
        text[text.range(of: "our team")!].link = URL(string: "mailto:team@fastmail.com")
        text[text.range(of: "https://a.example")!].link = URL(string: "https://a.example")
        #expect(MailHTMLWriter.write(text).text
                == "Write to alex@fastmail.com or our team <mailto:team@fastmail.com>, see https://a.example")
    }

    @Test func constrainsBeforeWriting() {
        var text = AttributedString("unsafe custom off-palette")
        text[text.range(of: "unsafe")!].link = URL(string: "javascript:alert(1)")
        text[text.range(of: "custom")!].font = Font.custom("Georgia", size: Font.default.resolve(in: Fixture.context).pointSize)
        text[text.range(of: "off-palette")!].foregroundColor = Color(red: 0.3, green: 0.1, blue: 0.9)
        text[text.range(of: "off-palette")!].backgroundColor = .yellow
        #expect(MailHTMLWriter.write(text).html == "<div>unsafe custom off-palette</div>")
    }

    @Test func worksOffTheMainActor() async {
        let text = Fixture.formattedBody()
        let expected = MailHTMLWriter.write(text)
        let detached = await Task.detached { MailHTMLWriter.write(text) }.value
        #expect(detached == expected)
    }
}
