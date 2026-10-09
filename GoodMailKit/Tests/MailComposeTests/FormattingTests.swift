import Foundation
import SwiftUI
import Testing
@testable import MailCompose

struct FormattingDefinitionTests {
    @Test func constrainDropsOffPaletteColoursAndForeignFonts() {
        var text = AttributedString("palette off times bold-helvetica big link script")
        text[text.range(of: "palette")!].foregroundColor = .red
        text[text.range(of: "off")!].foregroundColor = Color(red: 0.3, green: 0.6, blue: 0.1)
        text[text.range(of: "times")!].font = .custom("Times New Roman", size: 13)
        text[text.range(of: "bold-helvetica")!].font = Font.custom("Helvetica", size: 13).bold()
        text[text.range(of: "big")!].font = .system(size: 40)
        text[text.range(of: "link")!].link = URL(string: "https://example.com")
        text[text.range(of: "link")!][UnderlineAttribute.self] = Text.LineStyle(pattern: .dot, color: .red)
        text[text.range(of: "script")!].link = URL(string: "javascript:alert(1)")
        text[text.range(of: "script")!].backgroundColor = .yellow
        text[text.range(of: "script")!].kern = 3

        MailBodyFormatting().constrain(&text)

        func run(_ word: String) -> AttributedString.Runs.Run {
            text.runs[text.range(of: word)!.lowerBound]
        }
        #expect(run("palette").foregroundColor == .red)
        #expect(run("off").foregroundColor == nil)
        #expect(run("times").font == nil)
        #expect(run("bold-helvetica").font == MailFontStyle(isBold: true).font)
        #expect(MailFontStyle(run("big").font) == MailFontStyle(size: .huge))
        #expect(run("link").link == URL(string: "https://example.com"))
        #expect(run("link")[UnderlineAttribute.self] == .single)
        #expect(run("script").link == nil)
        #expect(run("script").backgroundColor == nil)
        #expect(run("script").kern == nil)
    }

    @Test func fontStylesRoundTrip() {
        for size in MailFontStyle.Size.allCases {
            for bits in 0..<8 {
                let style = MailFontStyle(isBold: bits & 1 != 0, isItalic: bits & 2 != 0, isMonospaced: bits & 4 != 0, size: size)
                #expect(MailFontStyle(style.font) == style)
            }
        }
        #expect(MailFontStyle().font == nil)
    }

    @Test func paletteEntriesAreFoundByColourAndCSS() {
        for entry in MailPalette.colors {
            #expect(MailPalette.entry(for: entry.color) == entry)
            #expect(MailPalette.entry(css: entry.css.uppercased()) == entry)
        }
        #expect(MailPalette.colors.count == 6)
        #expect(MailPalette.entry(for: .pink) == nil)
    }
}

struct NormalizerTests {
    @Test func flattensMarkdownBlocks() throws {
        let markdown = try AttributedString(
            markdown: "# Agenda\n\n- **Budget** review\n- *Hiring*\n  - nested\n\n1. first\n2. second\n\nSee `code` and ~~old~~.",
            options: .init(interpretedSyntax: .full))
        let normalized = MailBodyNormalizer.normalize(markdown)
        #expect(String(normalized.characters) == "Agenda\n• Budget review\n• Hiring\n• nested\n1. first\n2. second\nSee code and old.")
        #expect(MailHTMLWriter.write(normalized).html == """
            <div><span style="font-size: 170%"><b>Agenda</b></span></div><ul><li><b>Budget</b> review</li>\
            <li><i>Hiring</i></li><li>nested</li></ul><ol><li>first</li><li>second</li></ol>\
            <div>See <code>code</code> and <s>old</s>.</div>
            """)
        #expect(normalized.runs.allSatisfy { $0.presentationIntent == nil && $0.inlinePresentationIntent == nil })
    }

    @Test func unifiesLineBreaks() {
        let normalized = MailBodyNormalizer.normalize(AttributedString("a\r\nb\rc\u{2029}d"))
        #expect(String(normalized.characters) == "a\nb\nc\nd")
    }
}

struct BodyEditingTests {
    let context = Fixture.context

    @Test func formattingStateFollowsTheSelection() {
        let text = Fixture.formattedBody()
        let thanks = text.formattingState(for: Fixture.selection(of: "thanks", in: text), in: context)
        #expect(thanks.isBold && !thanks.isItalic && !thanks.isUnderlined && !thanks.isList)

        let notes = text.formattingState(for: Fixture.selection(of: "notes", in: text), in: context)
        #expect(notes.isItalic && notes.isUnderlined && !notes.isBold)

        let mixed = text.formattingState(for: Fixture.selection(of: "thanks for", in: text), in: context)
        #expect(!mixed.isBold)

        let details = text.formattingState(for: Fixture.selection(of: "details", in: text), in: context)
        #expect(details.size == .large && details.isStruckThrough)

        let colour = text.formattingState(for: Fixture.selection(of: "Three things", in: text), in: context)
        #expect(colour.color == MailPalette.colors[0])

        let link = text.formattingState(for: Fixture.selection(of: "example.com/doc", in: text), in: context)
        #expect(link.link == URL(string: "https://example.com/doc?utm_source=x&page=2"))

        let list = text.formattingState(for: Fixture.selection(of: "first point", in: text), in: context)
        #expect(list.isList && !list.isNumberedList)

        let mono = text.formattingState(for: Fixture.selection(of: "Cheers", in: text), in: context)
        #expect(mono.isMonospaced)
    }

    @Test func typingAttributesFollowFormattingAtTheCaret() {
        var text = AttributedString("plain")
        var selection = Fixture.caret(at: 5, in: text)
        text.updateFont({ $0.isBold = true }, selection: &selection, in: context)
        #expect(text.formattingState(for: selection, in: context).isBold)
        #expect(String(text.characters) == "plain")
    }

    @Test func togglesBulletedAndNumberedLists() {
        var text = AttributedString("intro\nalpha\nbeta\noutro")
        var selection = Fixture.selection(of: "alpha\nbeta", in: text)
        text.toggleList(numbered: false, selection: &selection)
        #expect(String(text.characters) == "intro\n• alpha\n• beta\noutro")
        #expect(text.formattingState(for: selection, in: context).isList)

        text.toggleList(numbered: true, selection: &selection)
        #expect(String(text.characters) == "intro\n1. alpha\n2. beta\noutro")
        #expect(text.formattingState(for: selection, in: context).isNumberedList)

        text.toggleList(numbered: true, selection: &selection)
        #expect(String(text.characters) == "intro\nalpha\nbeta\noutro")
        #expect(!text.formattingState(for: selection, in: context).isList)
    }

    @Test func numberingContinuesFromThePreviousItem() {
        var text = AttributedString("1. one\n2. two\nthree")
        var selection = Fixture.caret(at: text.characters.count, in: text)
        text.toggleList(numbered: true, selection: &selection)
        #expect(String(text.characters) == "1. one\n2. two\n3. three")
    }

    @Test func listToggleKeepsTheParagraphFont() {
        var text = AttributedString("item")
        text.font = MailFontStyle(isBold: true).font
        text.link = URL(string: "https://example.com")
        var selection = Fixture.selection(of: "item", in: text)
        text.toggleList(numbered: false, selection: &selection)
        let prefix = text.runs.first!
        #expect(String(text[prefix.range].characters) == "• ")
        #expect(prefix.font == MailFontStyle(isBold: true).font)
        #expect(prefix.link == nil)
    }

    @Test func returnContinuesOrEndsTheList() {
        var text = AttributedString("• one\n")
        var selection = Fixture.caret(at: 6, in: text)
        var changed = text.continueList(selection: &selection)
        #expect(changed)
        #expect(String(text.characters) == "• one\n• ")
        #expect(selection.indices(in: text) == .insertionPoint(text.endIndex))

        text.append(AttributedString("\n"))
        selection = Fixture.caret(at: text.characters.count, in: text)
        changed = text.continueList(selection: &selection)
        #expect(changed)
        #expect(String(text.characters) == "• one\n")
        #expect(selection.indices(in: text) == .insertionPoint(text.endIndex))

        var numbered = AttributedString("9. nine\nrest")
        selection = Fixture.caret(at: 8, in: numbered)
        changed = numbered.continueList(selection: &selection)
        #expect(changed)
        #expect(String(numbered.characters) == "9. nine\n10. rest")
        #expect(selection.indices(in: numbered) == .insertionPoint(numbered.characters.index(numbered.startIndex, offsetBy: 12)))

        var plain = AttributedString("not a list\n")
        selection = Fixture.caret(at: plain.characters.count, in: plain)
        changed = plain.continueList(selection: &selection)
        #expect(!changed)
        #expect(String(plain.characters) == "not a list\n")
    }

    @Test func linksAreInsertedOrApplied() {
        var text = AttributedString("Write me")
        var selection = Fixture.caret(at: 8, in: text)
        text.setLink(URL(string: "mailto:alex@fastmail.com"), selection: &selection)
        #expect(String(text.characters) == "Write mealex@fastmail.com")
        #expect(text.runs[text.range(of: "alex@fastmail.com")!.lowerBound].link == URL(string: "mailto:alex@fastmail.com"))

        selection = Fixture.selection(of: "Write", in: text)
        text.setLink(URL(string: "https://example.com/?utm_source=me"), selection: &selection)
        #expect(text.runs.first?.link == URL(string: "https://example.com/?utm_source=me"))
        text.setLink(nil, selection: &selection)
        #expect(text.runs.first?.link == nil)
    }

    @Test func colourCanBeRemovedAgain() {
        var text = AttributedString("colour")
        var selection = Fixture.selection(of: "colour", in: text)
        text.setColor(MailPalette.colors[3], selection: &selection)
        #expect(text.runs.first?.foregroundColor == MailPalette.colors[3].color)
        text.setColor(nil, selection: &selection)
        #expect(text.runs.first?.foregroundColor == nil)
    }
}
