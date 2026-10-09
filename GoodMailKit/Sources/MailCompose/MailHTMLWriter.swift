import Foundation
import MailPrivacy
import SwiftUI

/// The user's text as the two MIME alternatives of a message body.
public struct ComposedBody: Sendable, Equatable {
    public var html: String
    public var text: String

    public init(html: String, text: String) {
        self.html = html
        self.text = text
    }
}

/// Writes the composer's text as a small, inline-styled HTML fragment and a plain-text alternative.
///
/// The system's exporters don't produce mail-safe HTML (class-based CSS, private font names such as
/// `.AppleSystemUIFont`, the display colour on every paragraph; the formatting transferable is RTF only), so
/// this is ours: one `<div>` per paragraph, `<ul>`/`<ol>` for list paragraphs, and only tags and inline styles
/// every mail client renders. Links are written exactly as the user entered them.
public enum MailHTMLWriter {
    public static func write(_ text: AttributedString) -> ComposedBody {
        var text = MailBodyNormalizer.unifyingLineBreaks(text)
        MailBodyFormatting().constrain(&text)

        var html = ""
        var plain: [String] = []
        var openList: String?
        var number = 0
        for paragraph in paragraphs(of: text) {
            let item = ListItem(String(paragraph.characters))
            let tag = item.map { $0.isNumbered ? "ol" : "ul" }
            if openList != tag {
                if let openList { html += "</\(openList)>" }
                if let tag, let item {
                    number = (item.number ?? 1) - 1
                    html += "<\(tag)\(number == 0 ? "" : " start=\"\(number + 1)\"")>"
                }
                openList = tag
            }
            number += 1
            let body = item.map { dropPrefix($0.prefixLength, from: paragraph) } ?? paragraph
            let attributes = paragraphAttributes(paragraph)
            var content = inlineHTML(body)
            if content.isEmpty {
                content = "<br>"
            } else if content.hasSuffix("<br>") {
                // A line break at the very end of a block doesn't render; a second one makes it visible.
                content += "<br>"
            }
            html += item == nil ? "<div\(attributes)>\(content)</div>" : "<li\(attributes)>\(content)</li>"
            // Recipients' clients number an <ol> themselves, so the text alternative counts the same way.
            let prefix = item.map { $0.isNumbered ? "\(number). " : MailBodyNormalizer.bullet } ?? ""
            plain.append(prefix + plainText(body))
        }
        if let openList { html += "</\(openList)>" }
        return ComposedBody(html: html, text: plain.joined(separator: "\n"))
    }

    // MARK: Paragraphs

    static func paragraphs(of text: AttributedString) -> [AttributedSubstring] {
        var result: [AttributedSubstring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.characters.index(after: index)
            if text.characters[index] == "\n" {
                result.append(text[start..<index])
                start = next
            }
            index = next
        }
        result.append(text[start..<text.endIndex])
        return result
    }

    static func dropPrefix(_ count: Int, from paragraph: AttributedSubstring) -> AttributedSubstring {
        let start = paragraph.characters.index(paragraph.startIndex, offsetBy: count)
        return paragraph[start..<paragraph.endIndex]
    }

    /// Alignment and direction are paragraph attributes; the first run speaks for the paragraph.
    static func paragraphAttributes(_ paragraph: AttributedSubstring) -> String {
        var attributes = ""
        if paragraph.runs.first?.writingDirection == .rightToLeft { attributes += " dir=\"rtl\"" }
        switch paragraph.runs.first?.alignment {
        case .center?: attributes += " style=\"text-align: center\""
        case .right?: attributes += " style=\"text-align: right\""
        default: break
        }
        return attributes
    }

    // MARK: Inline

    enum Mark: Equatable {
        case link(String)
        case span(String)
        case bold, italic, underline, strike, code

        var open: String {
            switch self {
            case .link(let href): "<a href=\"\(HTMLEscaping.attribute(href))\">"
            case .span(let style): "<span style=\"\(style)\">"
            case .bold: "<b>"
            case .italic: "<i>"
            case .underline: "<u>"
            case .strike: "<s>"
            case .code: "<code>"
            }
        }

        var close: String {
            switch self {
            case .link: "</a>"
            case .span: "</span>"
            case .bold: "</b>"
            case .italic: "</i>"
            case .underline: "</u>"
            case .strike: "</s>"
            case .code: "</code>"
            }
        }
    }

    /// Marks in a fixed nesting order, so consecutive runs share open tags and nesting stays valid.
    static func marks(for run: AttributedString.Runs.Run) -> [Mark] {
        var marks: [Mark] = []
        if let url = run.link { marks.append(.link(url.absoluteString)) }
        let style = MailFontStyle(run.font)
        var css: [String] = []
        if let entry = MailPalette.entry(for: run.foregroundColor) { css.append("color: \(entry.css)") }
        if let size = style.size.css { css.append("font-size: \(size)") }
        if !css.isEmpty { marks.append(.span(css.joined(separator: "; "))) }
        if style.isBold { marks.append(.bold) }
        if style.isItalic { marks.append(.italic) }
        if run[UnderlineAttribute.self] != nil { marks.append(.underline) }
        if run[StrikethroughAttribute.self] != nil { marks.append(.strike) }
        if style.isMonospaced { marks.append(.code) }
        return marks
    }

    static func inlineHTML(_ paragraph: AttributedSubstring) -> String {
        var html = ""
        var open: [Mark] = []
        var afterSpace = true // carried across runs, so only real runs of spaces become no-break spaces
        for run in paragraph.runs {
            let wanted = marks(for: run)
            var common = 0
            while common < open.count, common < wanted.count, open[common] == wanted[common] { common += 1 }
            for mark in open[common...].reversed() { html += mark.close }
            for mark in wanted[common...] { html += mark.open }
            open = wanted
            html += escapeText(String(paragraph[run.range].characters), afterSpace: &afterSpace)
        }
        if afterSpace, html.hasSuffix(" ") { html = String(html.dropLast()) + "&nbsp;" }
        for mark in open.reversed() { html += mark.close }
        return html
    }

    static func plainText(_ paragraph: AttributedSubstring) -> String {
        var text = ""
        for run in paragraph.runs {
            let string = String(paragraph[run.range].characters)
            text += string
            if let url = run.link?.absoluteString {
                let shown = url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst(7)) : url
                if shown != string { text += " <\(url)>" }
            }
        }
        return text.replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    // MARK: Escaping

    /// Mail clients collapse whitespace, so runs of spaces alternate with no-break spaces as Apple Mail writes
    /// them, a space at either end of a paragraph is a no-break space, and tabs keep their width in a pre span.
    static func escapeText(_ text: String, afterSpace previousWasSpace: inout Bool) -> String {
        var output = ""
        for character in text {
            switch character {
            case "&": output += "&amp;"; previousWasSpace = false
            case "<": output += "&lt;"; previousWasSpace = false
            case ">": output += "&gt;"; previousWasSpace = false
            case "\u{2028}": output += "<br>"; previousWasSpace = true
            case "\t": output += "<span style=\"white-space: pre\">\t</span>"; previousWasSpace = false
            case " ":
                output += previousWasSpace ? "&nbsp;" : " "
                previousWasSpace.toggle()
            default: output.append(character); previousWasSpace = false
            }
        }
        return output
    }
}
