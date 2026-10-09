import Foundation
import SwiftUI

/// Brings any `AttributedString` into the flat form the composer edits: one paragraph per line, list items as
/// "• " or "1. " text, SwiftUI attributes only, constrained by `MailBodyFormatting`.
///
/// The editor ignores Foundation's block presentation intents (Markdown lists and quotes collapse into one line),
/// so text from Markdown, App Intents (`.mail.createDraft` passes `body: AttributedString?`) or the clipboard is
/// flattened before it is shown. Blocks are separated by an empty line, as they are when rendered, except items
/// of the same list; nested lists become one level, since the editor has no indentation.
public enum MailBodyNormalizer {
    public static let bullet = ListItem.bullet

    public static func normalize(_ input: AttributedString) -> AttributedString {
        var output = AttributedString()
        var previousBlock: Int?
        var previousList: Int?
        for (intent, range) in input.runs[\.presentationIntent] {
            var piece = AttributedString(input[range])
            let block = intent?.components.first?.identity
            let list = intent?.components.last { $0.kind == .orderedList || $0.kind == .unorderedList }?.identity
            if block != previousBlock, !output.characters.isEmpty {
                if output.characters.last != "\n" { output.append(AttributedString("\n")) }
                if intent != nil, previousBlock != nil, list == nil || list != previousList {
                    output.append(AttributedString("\n"))
                }
            }
            previousList = list
            if let intent, block != previousBlock {
                piece = prefix(for: intent) + piece
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let size: MailFontStyle.Size = level == 1 ? .huge : level == 2 ? .large : .normal
                        restyle(&piece) { $0.isBold = true; $0.size = size }
                    case .codeBlock:
                        restyle(&piece) { $0.isMonospaced = true }
                    default:
                        break
                    }
                }
            }
            previousBlock = block
            output.append(piece)
        }

        // Inline intents (bold, italic, code, strikethrough) become the attributes the toolbar edits.
        let inlineRuns = output.runs.compactMap { run in
            run.inlinePresentationIntent.map { (range: run.range, intent: $0, font: run[FontAttribute.self]) }
        }
        for run in inlineRuns {
            var style = MailFontStyle(run.font)
            if run.intent.contains(.stronglyEmphasized) { style.isBold = true }
            if run.intent.contains(.emphasized) { style.isItalic = true }
            if run.intent.contains(.code) { style.isMonospaced = true }
            output[run.range].font = style.font
            if run.intent.contains(.strikethrough) { output[run.range][StrikethroughAttribute.self] = .single }
            output[run.range].inlinePresentationIntent = nil
        }
        output = unifyingLineBreaks(output)
        MailBodyFormatting().constrain(&output)
        return output
    }

    private static func prefix(for intent: PresentationIntent) -> AttributedString {
        let kinds = intent.components.map(\.kind)
        guard let itemIndex = kinds.firstIndex(where: { if case .listItem = $0 { true } else { false } }),
              case .listItem(let ordinal) = kinds[itemIndex]
        else { return AttributedString() }
        let isOrdered = kinds[(itemIndex + 1)...].first { $0 == .orderedList || $0 == .unorderedList } == .orderedList
        return AttributedString(isOrdered ? "\(ordinal). " : bullet)
    }

    private static func restyle(_ text: inout AttributedString, _ change: (inout MailFontStyle) -> Void) {
        for (font, range) in text.runs[FontAttribute.self].map({ ($0.0, $0.1) }) {
            var style = MailFontStyle(font)
            change(&style)
            text[range].font = style.font
        }
    }

    /// The writer splits paragraphs at "\n" only, so CR LF, CR and the Unicode paragraph separator become "\n".
    static func unifyingLineBreaks(_ text: AttributedString) -> AttributedString {
        let breaks: Set<Character> = ["\r\n", "\r", "\u{2029}", "\u{85}"]
        let offsets = text.characters.enumerated().filter { breaks.contains($0.element) }.map(\.offset)
        guard !offsets.isEmpty else { return text }
        var text = text
        for offset in offsets.reversed() {
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            let end = text.characters.index(after: start)
            let attributes = text.runs[start].attributes
            text.replaceSubrange(start..<end, with: AttributedString("\n", attributes: attributes))
        }
        return text
    }
}
