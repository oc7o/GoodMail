import Foundation
import MailPrivacy

/// A tree of the strict HTML `OutgoingHTMLSanitizer` emits: allowlisted elements only, balanced tags,
/// double-quoted attributes, and "<" in text always escaped. It is not a parser for arbitrary HTML; anything that
/// hasn't been through the sanitizer must go through it first.
struct HTMLNode {
    enum Content {
        case element(name: String, attributes: [String: String], children: [HTMLNode])
        case text(String)
    }

    var content: Content
    /// Where the node is in the parsed string, for slicing it out verbatim.
    var range: Range<String.Index>

    var name: String? {
        if case .element(let name, _, _) = content { name } else { nil }
    }

    var attributes: [String: String] {
        if case .element(_, let attributes, _) = content { attributes } else { [:] }
    }

    var children: [HTMLNode] {
        if case .element(_, _, let children) = content { children } else { [] }
    }

    /// The text inside as it appears in the markup, with a line break for each <br>.
    var plainText: String {
        switch content {
        case .text(let text): text
        case .element(let name, _, let children): name == "br" ? "\n" : children.map(\.plainText).joined()
        }
    }

    /// Text of HTML's collapsible whitespace only; a no-break space is content.
    var isWhitespace: Bool {
        if case .text(let text) = content { text.allSatisfy(HTMLNode.collapsible.contains) } else { false }
    }

    static let collapsible: Set<Character> = [" ", "\t", "\n", "\r", "\r\n", "\u{0C}"]

    /// Deeper elements are unwrapped into their ancestor at this depth, so walking the tree recursively can't
    /// exhaust a thread's stack, whatever a draft contains. Real mail nests far less.
    static let maximumDepth = 64

    static func parse(_ html: String) -> [HTMLNode] {
        struct Open {
            var name: String
            var attributes: [String: String]
            var children: [HTMLNode] = []
            var start: String.Index
        }
        var stack: [Open] = []
        var unwrapped: [String] = []
        var roots: [HTMLNode] = []
        func append(_ node: HTMLNode) {
            if stack.isEmpty { roots.append(node) } else { stack[stack.count - 1].children.append(node) }
        }
        func close(at end: String.Index) {
            let open = stack.removeLast()
            append(HTMLNode(
                content: .element(name: open.name, attributes: open.attributes, children: open.children),
                range: open.start..<end))
        }

        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "<", let end = html[index...].firstIndex(of: ">") else {
                let textEnd = html[html.index(after: index)...].firstIndex(of: "<") ?? html.endIndex
                append(HTMLNode(content: .text(Entities.decode(String(html[index..<textEnd]))), range: index..<textEnd))
                index = textEnd
                continue
            }
            let tag = html[html.index(after: index)..<end]
            let after = html.index(after: end)
            if tag.hasPrefix("/") {
                let name = tag.dropFirst().lowercased()
                if unwrapped.last == name {
                    unwrapped.removeLast()
                } else if let position = stack.lastIndex(where: { $0.name == name }) {
                    while stack.count > position + 1 { close(at: index) }
                    close(at: after)
                }
            } else {
                let name = String(tag.prefix { !$0.isWhitespace }).lowercased()
                let attributes = Self.attributes(in: tag.drop { !$0.isWhitespace })
                if OutgoingHTMLSanitizer.voidElements.contains(name) {
                    append(HTMLNode(content: .element(name: name, attributes: attributes, children: []),
                                    range: index..<after))
                } else if stack.count >= maximumDepth || !unwrapped.isEmpty {
                    unwrapped.append(name)
                } else {
                    stack.append(Open(name: name, attributes: attributes, start: index))
                }
            }
            index = after
        }
        while !stack.isEmpty { close(at: html.endIndex) }
        return roots
    }

    /// ` name="value"` pairs, the only form the sanitizer writes.
    static func attributes(in text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var rest = text
        while let equals = rest.firstIndex(of: "="),
              let open = rest[equals...].firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"") {
            let name = rest[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            attributes[name] = Entities.decode(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return attributes
    }
}
