import Foundation
import MailPrivacy
import SwiftUI

/// Turns HTML back into editor text: drafts saved by GoodMail or written in another client.
///
/// The input goes through `OutgoingHTMLSanitizer` first and is then read by our own small reader, never by a
/// system HTML importer: those run WebKit, which fetches remote resources. What the editor can't hold is
/// simplified and reported in `dropped`, so a caller can show the original read-only instead.
public enum MailBodyHTMLReader {
    public enum Feature: String, Sendable, Hashable, CaseIterable {
        case images, tables, fonts, colors, sizes, nestedLists, quotes, preformatted, other
    }

    public struct Result: Sendable, Equatable {
        public var text: AttributedString
        /// Formatting that was simplified or left out; empty when the text is an exact reading.
        public var dropped: Set<Feature>
    }

    public static func read(_ html: String) -> Result {
        let clean = OutgoingHTMLSanitizer.sanitize(html, options: .init(cleansLinks: false)).html
        return read(nodes: HTMLNode.parse(clean))
    }

    static func read(nodes: [HTMLNode]) -> Result {
        var reader = Reader()
        reader.visit(nodes)
        reader.endParagraph()
        return Result(text: MailBodyNormalizer.normalize(reader.joined()), dropped: reader.dropped)
    }

    struct Reader {
        struct Style {
            var font = MailFontStyle()
            var underline = false
            var strike = false
            var color: Color?
            var link: URL?
            var preservesWhitespace = false
            /// `display: none`: left out of the editor, as it is left out of the rendered message.
            var isHidden = false

            var attributes: AttributeContainer {
                var container = AttributeContainer()
                container.font = font.font
                if underline { container[UnderlineAttribute.self] = .single }
                if strike { container[StrikethroughAttribute.self] = .single }
                container.foregroundColor = color
                container.link = link
                return container
            }
        }

        struct Block {
            var alignment: AttributedString.TextAlignment?
            var isRightToLeft = false
        }

        var paragraphs: [(text: AttributedString, block: Block)] = []
        var current = AttributedString()
        var hasContent = false
        /// <br>s not yet placed: line breaks inside the paragraph if more content follows, the end of the
        /// paragraph if a block boundary comes first (a trailing <br> doesn't render).
        var pendingBreaks = 0
        var trailingCollapsibleSpace = false
        var pendingPrefix: String?
        /// A <p> before or after: its margin reads as an empty line.
        var needsBlankLine = false
        var style = Style()
        var blocks = [Block()]
        var lists: [(ordered: Bool, counter: Int)] = []
        var dropped: Set<Feature> = []

        func joined() -> AttributedString {
            var text = AttributedString()
            for (index, paragraph) in paragraphs.enumerated() {
                var line = paragraph.text
                if index < paragraphs.count - 1 { line.append(AttributedString("\n")) }
                if let alignment = paragraph.block.alignment { line.alignment = alignment }
                if paragraph.block.isRightToLeft { line.writingDirection = .rightToLeft }
                text.append(line)
            }
            return text
        }

        // MARK: Paragraphs

        /// A block starts or ends here.
        mutating func boundary() {
            if pendingBreaks > 0 {
                appendLineBreaks(pendingBreaks - 1)
                pendingBreaks = 0
                endParagraph(force: true)
            } else {
                endParagraph()
            }
        }

        mutating func endParagraph(force: Bool = false) {
            guard hasContent || force || pendingBreaks > 0 else { return }
            if pendingBreaks > 0 {
                appendLineBreaks(pendingBreaks - 1)
                pendingBreaks = 0
            }
            if trailingCollapsibleSpace, current.characters.last == " " {
                current.removeSubrange(current.characters.index(before: current.endIndex)..<current.endIndex)
            }
            if needsBlankLine, let last = paragraphs.last, !last.text.characters.isEmpty {
                paragraphs.append((AttributedString(), last.block))
            }
            needsBlankLine = false
            var text = AttributedString()
            if let prefix = pendingPrefix { text = AttributedString(prefix) }
            text.append(current)
            paragraphs.append((text, blocks[blocks.count - 1]))
            current = AttributedString()
            hasContent = false
            trailingCollapsibleSpace = false
            pendingPrefix = nil
        }

        mutating func appendLineBreaks(_ count: Int) {
            guard count > 0 else { return }
            append(String(repeating: "\u{2028}", count: count))
            trailingCollapsibleSpace = false
        }

        mutating func append(_ string: String) {
            current.append(AttributedString(string, attributes: style.attributes))
            hasContent = true
        }

        // MARK: Text

        mutating func appendText(_ text: String) {
            var piece = ""
            func flush(_ reader: inout Reader) {
                if !piece.isEmpty { reader.append(piece) }
                piece = ""
            }
            for character in text {
                if style.preservesWhitespace, character == "\n" || character == "\r" || character == "\r\n" {
                    flush(&self)
                    pendingBreaks += 1
                } else if !style.preservesWhitespace, HTMLNode.collapsible.contains(character) {
                    // Collapsible: dropped at the start of a line and after another collapsible space.
                    let atLineStart = (!hasContent && piece.isEmpty) || pendingBreaks > 0
                    if atLineStart || trailingCollapsibleSpace { continue }
                    piece.append(" ")
                    trailingCollapsibleSpace = true
                } else {
                    if pendingBreaks > 0 {
                        flush(&self)
                        appendLineBreaks(pendingBreaks)
                        pendingBreaks = 0
                    }
                    piece.append(character == "\u{00A0}" ? " " : character)
                    trailingCollapsibleSpace = false
                }
            }
            flush(&self)
        }

        // MARK: Elements

        mutating func visit(_ nodes: [HTMLNode]) {
            for node in nodes { visit(node) }
        }

        mutating func visit(_ node: HTMLNode) {
            guard case .element(let name, let attributes, let children) = node.content else {
                if case .text(let text) = node.content { appendText(text) }
                return
            }
            switch name {
            case "br":
                pendingBreaks += 1
                return
            case "wbr", "col":
                return
            case "img":
                dropped.insert(.images)
                return
            case "hr":
                dropped.insert(.other)
                boundary()
                return
            default:
                break
            }

            let savedStyle = style
            defer { style = savedStyle }
            var block = blocks[blocks.count - 1]
            applyAttributes(of: name, attributes, to: &block)
            if style.isHidden { return }

            switch name {
            case "ul", "ol":
                boundary()
                if !lists.isEmpty { dropped.insert(.nestedLists) }
                let start = attributes["start"].flatMap { Int($0) } ?? 1
                lists.append((name == "ol", start - 1))
                visitBlock(children, block)
                lists.removeLast()
            case "li":
                boundary()
                var prefix = MailBodyNormalizer.bullet
                if var list = lists.popLast() {
                    list.counter = attributes["value"].flatMap { Int($0) } ?? list.counter + 1
                    lists.append(list)
                    if list.ordered { prefix = "\(list.counter). " }
                }
                pendingPrefix = prefix
                visitBlock(children, block)
                if pendingPrefix != nil { endParagraph(force: true) }
            case "p" where lists.isEmpty:
                boundary()
                if !paragraphs.isEmpty { needsBlankLine = true }
                visitBlock(children, block)
                if !paragraphs.isEmpty { needsBlankLine = true }
            case "td", "th":
                if hasContent {
                    append("\t")
                    trailingCollapsibleSpace = false
                }
                visit(children)
            case "p", "div", "blockquote", "center", "address", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "dl", "dt",
                 "dd", "caption", "table", "tbody", "thead", "tfoot", "tr":
                visitBlock(children, block)
            default:
                visit(children)
            }
        }

        mutating func visitBlock(_ children: [HTMLNode], _ block: Block) {
            boundary()
            blocks.append(block)
            visit(children)
            boundary()
            blocks.removeLast()
        }

        /// The element's own meaning and its style, dir and align attributes; reports what can't be kept.
        mutating func applyAttributes(of name: String, _ attributes: [String: String], to block: inout Block) {
            switch name {
            case "b", "strong": style.font.isBold = true
            case "i", "em", "cite", "dfn", "var", "address": style.font.isItalic = true
            case "u", "ins": style.underline = true
            case "s", "strike", "del": style.strike = true
            case "code", "tt", "kbd", "samp": style.font.isMonospaced = true
            case "a": style.link = attributes["href"].flatMap { URL(string: $0) }
            case "pre":
                dropped.insert(.preformatted)
                style.font.isMonospaced = true
                style.preservesWhitespace = true
            case "h1", "h2": dropped.insert(.sizes); style.font.isBold = true; style.font.size = .huge
            case "h3", "h4": dropped.insert(.sizes); style.font.isBold = true; style.font.size = .large
            case "h5", "h6": dropped.insert(.sizes); style.font.isBold = true
            case "big": dropped.insert(.sizes); style.font.size = .large
            case "small": dropped.insert(.sizes); style.font.size = .small
            case "blockquote": dropped.insert(.quotes)
            case "table", "tr", "td", "th", "caption", "tbody", "thead", "tfoot": dropped.insert(.tables)
            case "sub", "sup", "mark", "q", "bdo", "dl", "dt", "dd": dropped.insert(.other)
            case "center": block.alignment = .center
            case "font":
                if let color = attributes["color"] { applyColor(color) }
                if attributes["face"] != nil { dropped.insert(.fonts) }
                if let size = attributes["size"] {
                    dropped.insert(.sizes)
                    let value = Int(size.trimmingCharacters(in: .whitespaces)) ?? 3
                    style.font.size = value <= 2 ? .small : value == 3 ? .normal : value <= 5 ? .large : .huge
                }
            default: break
            }
            if attributes["bgcolor"] != nil { dropped.insert(.colors) }
            switch attributes["align"]?.lowercased() {
            case "center"?: block.alignment = .center
            case "right"?: block.alignment = .right
            case "justify"?: dropped.insert(.other)
            default: break
            }
            switch attributes["dir"]?.lowercased() {
            case "rtl"?: block.isRightToLeft = true
            case "ltr"?: block.isRightToLeft = false
            default: break
            }
            if let css = attributes["style"] { applyCSS(css, to: &block) }
        }

        mutating func applyCSS(_ css: String, to block: inout Block) {
            for declaration in css.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let property = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
                    .replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
                switch property {
                case "font-weight":
                    if ["bold", "bolder"].contains(value) || (Int(value) ?? 400) >= 600 { style.font.isBold = true }
                    if ["normal", "lighter"].contains(value) || (Int(value).map { $0 < 600 } ?? false) {
                        style.font.isBold = false
                    }
                case "font-style":
                    style.font.isItalic = value.hasPrefix("italic") || value.hasPrefix("oblique")
                case "text-decoration", "text-decoration-line":
                    if value.contains("underline") { style.underline = true }
                    if value.contains("line-through") { style.strike = true }
                case "font-family":
                    if Self.isMonospaced(family: value) {
                        style.font.isMonospaced = true
                    } else {
                        dropped.insert(.fonts)
                    }
                case "font":
                    dropped.insert(.fonts)
                case "font-size":
                    applySize(value)
                case "color":
                    applyColor(value)
                case "background", "background-color":
                    if !Self.isNeutral(value) { dropped.insert(.colors) }
                case "text-align":
                    switch value {
                    case "center": block.alignment = .center
                    case "right": block.alignment = .right
                    case "left", "start": block.alignment = nil
                    case "justify": dropped.insert(.other)
                    default: break
                    }
                case "direction":
                    block.isRightToLeft = value == "rtl"
                case "white-space":
                    if value.hasPrefix("pre") || value == "break-spaces" { style.preservesWhitespace = true }
                case "display":
                    if value == "none" {
                        style.isHidden = true
                        dropped.insert(.other)
                    }
                case "vertical-align":
                    if ["sub", "super"].contains(value) { dropped.insert(.other) }
                case "text-transform", "font-variant", "letter-spacing", "word-spacing", "text-indent":
                    if !Self.isNeutral(value) && value != "normal" { dropped.insert(.other) }
                default:
                    break
                }
            }
        }

        mutating func applySize(_ value: String) {
            let exact: [String: MailFontStyle.Size] = ["80%": .small, "100%": .normal, "130%": .large, "170%": .huge]
            if let size = exact[value] {
                style.font.size = size
                return
            }
            if Self.isNeutral(value) || value == "medium" { return }
            dropped.insert(.sizes)
            let keywords: [String: MailFontStyle.Size] = [
                "xx-small": .small, "x-small": .small, "small": .small, "smaller": .small,
                "large": .large, "larger": .large, "x-large": .huge, "xx-large": .huge, "xxx-large": .huge,
            ]
            if let size = keywords[value] {
                style.font.size = size
                return
            }
            // Relative to the 16px default of web views and most mail clients.
            let number = Double(value.prefix { $0.isNumber || $0 == "." }) ?? 0
            let ratio: Double = if value.hasSuffix("%") { number / 100 }
                else if value.hasSuffix("px") { number / 16 }
                else if value.hasSuffix("pt") { number / 12 }
                else if value.hasSuffix("em") || value.hasSuffix("rem") { number }
                else { 1 }
            style.font.size = MailFontStyle.Size.nearest(to: ratio)
        }

        mutating func applyColor(_ value: String) {
            if let entry = MailPalette.entry(css: value) {
                style.color = entry.color
            } else if !Self.isNeutral(value) {
                dropped.insert(.colors)
            }
        }

        static func isNeutral(_ value: String) -> Bool {
            ["inherit", "initial", "unset", "transparent", "none", "currentcolor", "revert"].contains(value)
        }

        static func isMonospaced(family: String) -> Bool {
            ["monospace", "mono", "courier", "consolas", "menlo", "monaco"].contains { family.contains($0) }
        }
    }
}
