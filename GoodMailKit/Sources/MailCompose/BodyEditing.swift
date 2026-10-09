import Foundation
import SwiftUI

/// The formatting commands of the composer, as pure operations on the body and the editor's selection.
///
/// The editor writes text and selection through separate bindings, the selection after the text, so the view
/// must not run these from inside the text binding's setter; `continueList` in particular belongs on the next
/// main-actor turn after a keystroke.
extension AttributedString {
    /// A trait counts as on when every part of the selection has it, or for an insertion point the typing
    /// attributes, as in Mail.
    public func formattingState(for selection: AttributedTextSelection, in context: Font.Context) -> FormattingState {
        var state = FormattingState()
        let containers = Array(selection.attributes(in: self))
        if !containers.isEmpty {
            let styles = containers.map { MailFontStyle($0.font, in: context) }
            state.isBold = styles.allSatisfy(\.isBold)
            state.isItalic = styles.allSatisfy(\.isItalic)
            state.isMonospaced = styles.allSatisfy(\.isMonospaced)
            state.isUnderlined = containers.allSatisfy { $0[UnderlineAttribute.self] != nil }
            state.isStruckThrough = containers.allSatisfy { $0[StrikethroughAttribute.self] != nil }
            state.size = Set(styles.map(\.size)).count == 1 ? styles[0].size : .normal
            let colors = containers.map { MailPalette.entry(for: $0.foregroundColor) }
            state.color = Set(colors).count == 1 ? colors[0] : nil
            state.link = containers.lazy.compactMap(\.link).first
        }
        let kinds = paragraphStarts(for: selection).map { listItem(at: $0)?.isNumbered }
        state.isList = !kinds.isEmpty && kinds.allSatisfy { $0 != nil }
        state.isNumberedList = !kinds.isEmpty && kinds.allSatisfy { $0 == true }
        return state
    }

    // MARK: Character formatting

    /// Bold, italic, monospace and size: `change` edits the style of each selected run, or the typing style.
    public mutating func updateFont(
        _ change: (inout MailFontStyle) -> Void, selection: inout AttributedTextSelection, in context: Font.Context
    ) {
        transformAttributes(in: &selection) { container in
            var style = MailFontStyle(container.font, in: context)
            change(&style)
            container.font = style.font
        }
    }

    public mutating func setUnderline(_ on: Bool, selection: inout AttributedTextSelection) {
        transformAttributes(in: &selection) { $0[UnderlineAttribute.self] = on ? .single : nil }
    }

    public mutating func setStrikethrough(_ on: Bool, selection: inout AttributedTextSelection) {
        transformAttributes(in: &selection) { $0[StrikethroughAttribute.self] = on ? .single : nil }
    }

    public mutating func setColor(_ entry: MailPalette.Entry?, selection: inout AttributedTextSelection) {
        transformAttributes(in: &selection) { $0.foregroundColor = entry?.color }
    }

    /// Links the selection, or at an insertion point inserts the address as linked text. The URL is used
    /// exactly as given: links the user writes are sent as entered.
    public mutating func setLink(_ url: URL?, selection: inout AttributedTextSelection) {
        if case .insertionPoint = selection.indices(in: self), let url {
            var shown = url.absoluteString
            if shown.lowercased().hasPrefix("mailto:") { shown = String(shown.dropFirst(7)) }
            var inserted = AttributedString(shown)
            inserted.mergeAttributes(selection.typingAttributes(in: self), mergePolicy: .keepCurrent)
            inserted.link = url
            replaceSelection(&selection, with: inserted)
        } else {
            transformAttributes(in: &selection) { $0.link = url }
        }
    }

    // MARK: Lists

    /// Lists are paragraphs starting with "• " or "1. ": the editor has no list attributes, and the HTML writer
    /// turns these paragraphs into real `<ul>` and `<ol>` lists. Toggling a list kind that every selected
    /// paragraph already has removes it; otherwise every selected paragraph becomes an item of that kind.
    public mutating func toggleList(numbered: Bool, selection: inout AttributedTextSelection) {
        let starts = paragraphStarts(for: selection)
        guard !starts.isEmpty else { return }
        let items = starts.map { listItem(at: $0) }
        let removing = items.allSatisfy { $0?.isNumbered == numbered }
        var number = numbered && !removing ? numberBefore(starts[0]) + 1 : 1
        let edits = zip(starts, items).map { start, item in
            let offset = characters.distance(from: startIndex, to: start)
            defer { if numbered { number += 1 } }
            return (offset: offset, removeCount: item?.prefixLength ?? 0,
                    insert: removing ? nil : (numbered ? "\(number). " : ListItem.bullet))
        }
        transform(updating: &selection) { text in
            for edit in edits.reversed() {
                let start = text.characters.index(text.startIndex, offsetBy: edit.offset)
                var attributes = AttributeContainer()
                if start < text.endIndex { attributes = text.runs[start].attributes }
                if edit.removeCount > 0 {
                    let end = text.characters.index(start, offsetBy: edit.removeCount)
                    text.removeSubrange(start..<end)
                }
                if let insert = edit.insert {
                    var prefix = AttributedString(insert, attributes: attributes)
                    prefix.link = nil
                    prefix[UnderlineAttribute.self] = nil
                    prefix[StrikethroughAttribute.self] = nil
                    text.insert(prefix, at: start)
                }
            }
        }
    }

    /// After Return in a list item: starts the next item, or ends the list when the item was empty.
    /// Returns whether it changed anything.
    @discardableResult
    public mutating func continueList(selection: inout AttributedTextSelection) -> Bool {
        guard case .insertionPoint(let caret) = selection.indices(in: self), caret > startIndex else { return false }
        let newline = characters.index(before: caret)
        guard characters[newline] == "\n" else { return false }
        let paragraphStart = characters[..<newline].lastIndex(of: "\n").map { characters.index(after: $0) }
            ?? startIndex
        guard let item = listItem(at: paragraphStart) else { return false }
        let typing = selection.typingAttributes(in: self)
        let startOffset = characters.distance(from: startIndex, to: paragraphStart)
        let caretOffset = characters.distance(from: startIndex, to: caret)
        let itemLength = characters.distance(from: paragraphStart, to: newline)

        let newCaret: Int
        if itemLength == item.prefixLength {
            // An empty item: Return leaves the list, dropping the empty item and the new line.
            let start = characters.index(startIndex, offsetBy: startOffset)
            removeSubrange(start..<characters.index(startIndex, offsetBy: caretOffset))
            newCaret = startOffset
        } else {
            let prefix = item.number.map { "\($0 + 1). " } ?? ListItem.bullet
            insert(AttributedString(prefix), at: characters.index(startIndex, offsetBy: caretOffset))
            newCaret = caretOffset + prefix.count
        }
        selection = AttributedTextSelection(
            insertionPoint: characters.index(startIndex, offsetBy: newCaret), typingAttributes: typing)
        return true
    }

    // MARK: Paragraphs

    /// The start indices of the paragraphs the selection touches, in order.
    func paragraphStarts(for selection: AttributedTextSelection) -> [AttributedString.Index] {
        let ranges: [Range<AttributedString.Index>] = switch selection.indices(in: self) {
        case .insertionPoint(let index): [index..<index]
        case .ranges(let set): Array(set.ranges)
        }
        var starts: [AttributedString.Index] = []
        for range in ranges {
            var index = characters[..<range.lowerBound].lastIndex(of: "\n").map { characters.index(after: $0) }
                ?? startIndex
            starts.append(index)
            while let next = characters[index..<range.upperBound].firstIndex(of: "\n") {
                index = characters.index(after: next)
                guard index < range.upperBound else { break }
                starts.append(index)
            }
        }
        var unique: [AttributedString.Index] = []
        for start in starts.sorted() where unique.last != start { unique.append(start) }
        return unique
    }

    func listItem(at paragraphStart: AttributedString.Index) -> ListItem? {
        let end = characters[paragraphStart...].firstIndex(of: "\n") ?? endIndex
        return ListItem(String(characters[paragraphStart..<end]))
    }

    /// The number of the numbered item right before the paragraph at `start`, or 0.
    func numberBefore(_ start: AttributedString.Index) -> Int {
        guard start > startIndex else { return 0 }
        let previousEnd = characters.index(before: start)
        let previousStart = characters[..<previousEnd].lastIndex(of: "\n").map { characters.index(after: $0) }
            ?? startIndex
        return listItem(at: previousStart)?.number ?? 0
    }
}

/// The list prefix of a paragraph: "• " or a number such as "12. ". The HTML writer and the editor agree on it.
struct ListItem: Equatable {
    static let bullet = "• "

    /// nil for a bulleted item.
    var number: Int?
    var prefixLength: Int
    var isNumbered: Bool { number != nil }

    init?(_ paragraph: String) {
        if paragraph.hasPrefix(Self.bullet) {
            number = nil
            prefixLength = 2
        } else if paragraph.hasPrefix("\t•\t") {
            // Writing Tools' list format.
            number = nil
            prefixLength = 3
        } else if let match = paragraph.prefixMatch(of: #/(\d{1,3})\. /#), let value = Int(match.output.1) {
            number = value
            prefixLength = match.output.0.count
        } else {
            return nil
        }
    }
}
