/// Which part of a document a `<style>` sheet restyles, judged by the subject of each selector: the element type,
/// classes and id its last compound names.
///
/// The sanitizer drops style sheets. Whether that changes how the text looks depends on whether a rule applies to
/// anything: Fastmail's web client puts `p.MsoNormal{margin:0}` into every message it writes, which only matters
/// when the message has such paragraphs, as Outlook's do. The judgement errs towards "applies": combinators,
/// attribute selectors and structural pseudo-classes are ignored, and class and id names match case-insensitively,
/// as in quirks mode, which most mail is in.
struct StyleSheetReach {
    /// Where each element type ("t:p"), class ("c:mso"), type with class ("tc:p.mso") and id ("i:x") first occurs.
    var firstOffsets: [String: Int] = [:]
    /// More distinct names than are worth remembering: every rule is then assumed to apply from the start.
    var isOverfull = false

    static let capacity = 20_000

    mutating func record(element name: String, classes: [Substring], id: String?, at offset: Int) {
        guard !isOverfull else { return }
        func note(_ key: String) {
            guard firstOffsets[key] == nil else { return }
            firstOffsets[key] = offset
            if firstOffsets.count > Self.capacity { isOverfull = true }
        }
        note("t:" + name)
        for token in classes {
            let lowered = token.lowercased()
            note("c:" + lowered)
            note("tc:" + name + "." + lowered)
        }
        if let id, !id.isEmpty { note("i:" + id.lowercased()) }
    }

    /// The first offset a rule of `css` may restyle; nil when no rule applies to anything recorded.
    func firstAffected(by css: String) -> Int? {
        var first: Int?
        for selector in Self.selectors(in: Self.withoutComments(css)) {
            guard let offset = firstMatch(of: selector) else { continue }
            first = min(first ?? offset, offset)
        }
        return first
    }

    func firstMatch(of selector: Substring) -> Int? {
        let lowered = selector.lowercased()
        if Self.inertPseudoClasses.contains(where: { lowered.contains($0) }) { return nil }
        guard let subject = Self.subject(of: Substring(lowered)) else { return nil }
        if isOverfull || subject.isDocument { return 0 }
        var keys: [String] = []
        if let type = subject.type { keys.append("t:" + type) }
        for name in subject.classes { keys.append(subject.type.map { "tc:\($0).\(name)" } ?? "c:" + name) }
        if let id = subject.id { keys.append("i:" + id) }
        if keys.isEmpty { return firstOffsets.values.min() }
        // Every key must occur for an element to match; it can't match before the last of them first occurs.
        var latest = 0
        for key in keys {
            guard let offset = firstOffsets[key] else { return nil }
            latest = max(latest, offset)
        }
        return latest
    }

    /// Pseudo-classes and elements that never apply to a message as it is shown.
    static let inertPseudoClasses = [
        ":hover", ":active", ":focus", ":visited", ":target", "::selection", "::-moz-selection", "::placeholder",
        "::-webkit-", ":-ms-", ":-moz-",
    ]

    struct Subject {
        var type: String?
        var classes: [String] = []
        var id: String?
        /// `html`, `body` or `:root`: everything inherits from it.
        var isDocument = false
    }

    /// The last compound selector of `selector`, which names the elements the rule styles.
    static func subject(of selector: Substring) -> Subject? {
        var depth = 0
        var start = selector.startIndex
        for index in selector.indices {
            switch selector[index] {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case " ", "\t", "\n", "\r", "\u{0C}", ">", "+", "~":
                if depth == 0 { start = selector.index(after: index) }
            default: break
            }
        }
        let compound = selector[start...]
        guard !compound.isEmpty else { return nil }
        var subject = Subject()
        var index = compound.startIndex
        let type = identifier(in: compound, from: &index)
        if !type.isEmpty {
            subject.type = type
        } else if index < compound.endIndex, compound[index] == "*" {
            index = compound.index(after: index)
        }
        if let bar = compound[index...].first, bar == "|" {   // namespace prefix: the type follows it
            index = compound.index(after: index)
            let local = identifier(in: compound, from: &index)
            subject.type = local.isEmpty ? nil : local
        }
        while index < compound.endIndex {
            let marker = compound[index]
            index = compound.index(after: index)
            switch marker {
            case ".": subject.classes.append(identifier(in: compound, from: &index))
            case "#": subject.id = identifier(in: compound, from: &index)
            case "[": skip(past: "]", in: compound, from: &index)
            case ":":
                if index < compound.endIndex, compound[index] == ":" { index = compound.index(after: index) }
                let name = identifier(in: compound, from: &index)
                if name == "root" { subject.isDocument = true }
                if index < compound.endIndex, compound[index] == "(" { skip(past: ")", in: compound, from: &index) }
            default: return nil   // not a selector GoodMail understands; a browser would drop the rule too
            }
        }
        if subject.type == "html" || subject.type == "body" { subject.isDocument = true }
        return subject
    }

    static func identifier(in text: Substring, from index: inout Substring.Index) -> String {
        var name = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { break }
                name.append(text[index])
            } else if character.isLetter || character.isNumber || character == "-" || character == "_"
                        || !character.isASCII {
                name.append(character)
            } else {
                break
            }
            index = text.index(after: index)
        }
        return name
    }

    static func skip(past closing: Character, in text: Substring, from index: inout Substring.Index) {
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                depth -= 1
                if depth <= 0, character == closing { return }
            }
        }
    }

    static func withoutComments(_ css: String) -> String {
        var output = ""
        var rest = Substring(css)
        while let open = rest.range(of: "/*") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "*/") else { return output }
            rest = rest[close.upperBound...]
        }
        return output + rest
    }

    /// The selectors of every rule with declarations, inside `@media` and similar group rules too; rules inside
    /// `@font-face`, `@keyframes` or `@page` style no element. Group rules nested deeper than anyone writes them
    /// count as styling everything.
    static func selectors(in css: String, depth: Int = 0) -> [Substring] {
        var selectors: [Substring] = []
        var rest = Substring(css)
        while let brace = rest.firstIndex(where: { $0 == "{" || $0 == ";" }) {
            let prelude = rest[..<brace].trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "<!--", with: "").replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rest[brace] == ";" {
                rest = rest[rest.index(after: brace)...]   // @import, @charset, @namespace: nothing to style
                continue
            }
            let blockStart = rest.index(after: brace)
            var braces = 1
            var quote: Character?
            var index = blockStart
            while index < rest.endIndex {
                let character = rest[index]
                if let open = quote {
                    if character == "\\" {
                        index = rest.index(after: index)
                        if index == rest.endIndex { break }
                    } else if character == open {
                        quote = nil
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "{" {
                    braces += 1
                } else if character == "}" {
                    braces -= 1
                    if braces == 0 { break }
                }
                index = rest.index(after: index)
            }
            let block = rest[blockStart..<index]
            rest = index < rest.endIndex ? rest[rest.index(after: index)...] : rest[rest.endIndex...]
            if prelude.hasPrefix("@") {
                let name = prelude.dropFirst().prefix { $0.isLetter || $0 == "-" }.lowercased()
                if groupRules.contains(name) {
                    selectors += depth < 8 ? Self.selectors(in: String(block), depth: depth + 1) : ["*"]
                }
                continue
            }
            guard !block.allSatisfy(\.isWhitespace) else { continue }
            selectors += splitList(Substring(prelude))
        }
        return selectors
    }

    static let groupRules: Set<String> = ["media", "supports", "document", "-moz-document", "container", "layer", "scope"]

    static func splitList(_ list: Substring) -> [Substring] {
        var parts: [Substring] = []
        var depth = 0
        var start = list.startIndex
        for index in list.indices {
            switch list[index] {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(list[start..<index])
                start = list.index(after: index)
            default: break
            }
        }
        parts.append(list[start...])
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { Substring($0) }
    }
}
