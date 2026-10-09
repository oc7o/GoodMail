import Foundation

/// Re-serialises untrusted HTML (a quoted original, an HTML signature, a draft written elsewhere) through an
/// allowlist, for HTML that leaves the device or is read back into the composer.
///
/// It parses loosely and emits strictly: input is tokenised forgivingly, but the output contains only allowlisted
/// elements and attributes, every text node and attribute value is re-escaped, and tags are balanced by our own
/// stack. A mis-parse therefore costs fidelity, never safety.
public enum OutgoingHTMLSanitizer {
    public enum RemoteImages: Sendable {
        case keep
        case remove
    }

    public struct Options: Sendable {
        public var remoteImages: RemoteImages
        /// `data:` images whose decoded size exceeds this are dropped.
        public var maxDataImageBytes: Int
        /// Strips tracking parameters from links. Quoted and forwarded content is cleaned; the user's own text
        /// read back from a draft is not, because links the user writes are sent exactly as entered.
        public var cleansLinks: Bool
        /// `class` tokens kept on any element, e.g. "signature" so a draft's signature block can be found again.
        public var allowedClasses: Set<String>

        public init(
            remoteImages: RemoteImages = .keep, maxDataImageBytes: Int = 256 * 1024, cleansLinks: Bool = true,
            allowedClasses: Set<String> = []
        ) {
            self.remoteImages = remoteImages
            self.maxDataImageBytes = maxDataImageBytes
            self.cleansLinks = cleansLinks
            self.allowedClasses = allowedClasses
        }
    }

    public struct Result: Sendable, Equatable {
        public var html: String
        /// `cid:` references kept, in order of appearance, so the original inline parts can be attached by blob id.
        public var contentIDs: [String]
        public var removedTrackers: Int
        public var removedRemoteImages: Int
        /// A plain-text rendering, for the text/plain alternative of HTML-only content.
        public var text: String
    }

    public static func sanitize(_ html: String, options: Options = Options()) -> Result {
        var state = State(source: Array(html.utf8), options: options)
        state.run()
        return Result(
            html: state.output, contentIDs: state.contentIDs, removedTrackers: state.trackers,
            removedRemoteImages: state.remoteImagesRemoved, text: state.plainText())
    }

    // MARK: Allowlists

    static let allowedElements: Set<String> = [
        "a", "abbr", "address", "b", "bdi", "bdo", "big", "blockquote", "br", "caption", "center", "cite", "code",
        "col", "colgroup", "dd", "del", "dfn", "div", "dl", "dt", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "s", "samp", "small", "span", "strike",
        "strong", "sub", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var", "wbr",
    ]
    /// Dropped together with everything inside them.
    static let droppedWithContent: Set<String> = [
        "script", "style", "title", "textarea", "iframe", "object", "embed", "applet", "frame", "frameset",
        "noscript", "noembed", "noframes", "template", "svg", "math", "canvas", "audio", "video", "select",
        "button", "xmp", "plaintext",
    ]
    /// Their content is never markup, so it is skipped up to the matching end tag without tokenising it.
    static let rawText: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "noscript", "noembed", "noframes", "iframe", "plaintext",
    ]
    package static let voidElements: Set<String> = [
        "br", "hr", "img", "wbr", "col", "input", "meta", "link", "base", "source", "area", "param", "track",
    ]
    static let blockElements: Set<String> = [
        "address", "blockquote", "center", "div", "dl", "dd", "dt", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li",
        "ol", "p", "pre", "table", "tr", "ul", "caption",
    ]

    static let globalAttributes: Set<String> = [
        "dir", "lang", "title", "style", "align", "valign", "width", "height", "bgcolor",
    ]
    static let elementAttributes: [String: Set<String>] = [
        "a": ["href"],
        "img": ["src", "alt"],
        "font": ["color", "face", "size"],
        "table": ["border", "cellpadding", "cellspacing"],
        "td": ["colspan", "rowspan", "nowrap"],
        "th": ["colspan", "rowspan", "nowrap", "scope"],
        "col": ["span"], "colgroup": ["span"],
        "ol": ["start", "type"], "ul": ["type"], "li": ["value"],
        "blockquote": ["type"],
    ]
    static let cssProperties: Set<String> = [
        "color", "background", "background-color", "font", "font-family", "font-size", "font-style", "font-weight",
        "font-variant", "text-align", "text-decoration", "text-decoration-line", "text-indent", "text-transform",
        "letter-spacing", "word-spacing", "line-height", "white-space", "vertical-align", "direction",
        "unicode-bidi", "margin", "margin-top", "margin-right", "margin-bottom", "margin-left", "padding",
        "padding-top", "padding-right", "padding-bottom", "padding-left", "border", "border-top", "border-right",
        "border-bottom", "border-left", "border-color", "border-style", "border-width", "border-radius",
        "border-collapse", "border-spacing", "width", "height", "min-width", "max-width", "min-height",
        "max-height", "display", "list-style-type", "table-layout", "overflow-wrap", "word-break", "word-wrap",
        "float", "clear",
    ]
    static let displayValues: Set<String> = [
        "block", "inline", "inline-block", "none", "table", "table-row", "table-cell", "list-item",
    ]
    static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    static let dataImageTypes = ["data:image/png", "data:image/gif", "data:image/jpeg", "data:image/jpg", "data:image/webp"]

    // MARK: Tokeniser and emitter

    struct State {
        let source: [UInt8]
        let options: Options
        var position = 0
        var output = ""
        var stack: [String] = []
        var contentIDs: [String] = []
        var trackers = 0
        var remoteImagesRemoved = 0
        var text = ""
        var preDepth = 0
        var linkStack: [String?] = []

        init(source: [UInt8], options: Options) {
            self.source = source
            self.options = options
        }

        mutating func run() {
            while position < source.count {
                if source[position] == UInt8(ascii: "<"), let consumed = tag() {
                    position = consumed
                } else {
                    let start = position
                    position += 1
                    while position < source.count, source[position] != UInt8(ascii: "<") { position += 1 }
                    emitText(source[start..<position])
                }
            }
            while let open = stack.popLast() {
                output += "</\(open)>"
                closedForText(open)
            }
        }

        /// Consumes the markup construct at `position`; returns the index after it, or nil if "<" is just text.
        mutating func tag() -> Int? {
            let next = position + 1
            guard next < source.count else { return nil }
            if starts(with: "<!--") {
                return find("-->", from: position + 4).map { $0 + 3 } ?? source.count
            }
            if source[next] == UInt8(ascii: "!") || source[next] == UInt8(ascii: "?") {
                return find(">", from: next).map { $0 + 1 } ?? source.count
            }
            let isEnd = source[next] == UInt8(ascii: "/")
            var cursor = isEnd ? next + 1 : next
            guard cursor < source.count, isLetter(source[cursor]) else { return nil }
            let nameStart = cursor
            while cursor < source.count, !isSpace(source[cursor]), source[cursor] != UInt8(ascii: ">"),
                  source[cursor] != UInt8(ascii: "/") {
                cursor += 1
            }
            let name = String(decoding: source[nameStart..<cursor], as: UTF8.self).lowercased()
            var attributes: [(String, String)] = []
            while cursor < source.count, source[cursor] != UInt8(ascii: ">") {
                if isSpace(source[cursor]) || source[cursor] == UInt8(ascii: "/") {
                    cursor += 1
                    continue
                }
                let attributeStart = cursor
                while cursor < source.count, !isSpace(source[cursor]), source[cursor] != UInt8(ascii: "="),
                      source[cursor] != UInt8(ascii: ">"),
                      !(source[cursor] == UInt8(ascii: "/") && cursor > attributeStart) {
                    cursor += 1
                }
                let attributeName = String(decoding: source[attributeStart..<cursor], as: UTF8.self).lowercased()
                while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
                var value = ""
                if cursor < source.count, source[cursor] == UInt8(ascii: "=") {
                    cursor += 1
                    while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
                    if cursor < source.count, source[cursor] == UInt8(ascii: "\"") || source[cursor] == UInt8(ascii: "'") {
                        let quote = source[cursor]
                        let valueStart = cursor + 1
                        cursor = valueStart
                        while cursor < source.count, source[cursor] != quote { cursor += 1 }
                        value = String(decoding: source[valueStart..<min(cursor, source.count)], as: UTF8.self)
                        cursor += 1
                    } else {
                        let valueStart = cursor
                        while cursor < source.count, !isSpace(source[cursor]), source[cursor] != UInt8(ascii: ">") {
                            cursor += 1
                        }
                        value = String(decoding: source[valueStart..<cursor], as: UTF8.self)
                    }
                }
                if !attributeName.isEmpty { attributes.append((attributeName, Entities.decode(value))) }
            }
            let selfClosing = cursor > 0 && cursor < source.count && source[cursor - 1] == UInt8(ascii: "/")
            let after = min(cursor + 1, source.count)
            if isEnd {
                // Browsers treat </br> as <br>.
                if name == "br" { startTag(name, []) } else { endTag(name) }
                return after
            }
            if OutgoingHTMLSanitizer.rawText.contains(name) {
                let end = findCaseInsensitive("</\(name)", from: after) ?? source.count
                return find(">", from: end).map { $0 + 1 } ?? source.count
            }
            if OutgoingHTMLSanitizer.droppedWithContent.contains(name) {
                return selfClosing ? after : (matchingEnd(of: name, from: after) ?? after)
            }
            startTag(name, attributes)
            return after
        }

        // MARK: Elements

        mutating func startTag(_ name: String, _ attributes: [(String, String)]) {
            guard OutgoingHTMLSanitizer.allowedElements.contains(name) else { return } // unwrap unknown elements
            implicitlyClose(before: name)
            var kept: [(String, String)] = []
            for (attribute, value) in attributes where !kept.contains(where: { $0.0 == attribute }) {
                if attribute == "class" {
                    let classes = value.split(whereSeparator: \.isWhitespace).map(String.init)
                        .filter(options.allowedClasses.contains)
                    if !classes.isEmpty { kept.append((attribute, classes.joined(separator: " "))) }
                    continue
                }
                guard OutgoingHTMLSanitizer.globalAttributes.contains(attribute)
                        || OutgoingHTMLSanitizer.elementAttributes[name]?.contains(attribute) == true
                else { continue }
                switch attribute {
                case "href":
                    if let href = safeLink(value) { kept.append((attribute, href)) }
                case "src":
                    guard let src = imageSource(value, attributes: attributes) else { return } // drops the img
                    kept.append((attribute, src))
                case "style":
                    let style = filterStyle(value)
                    if !style.isEmpty { kept.append((attribute, style)) }
                case "bgcolor", "color":
                    if value.range(of: #"^#?[0-9a-zA-Z]{1,20}$"#, options: .regularExpression) != nil {
                        kept.append((attribute, value))
                    }
                default:
                    if value.count <= 200 { kept.append((attribute, value)) }
                }
            }
            if name == "img", !kept.contains(where: { $0.0 == "src" }) { return }
            output += "<\(name)"
            for (attribute, value) in kept { output += " \(attribute)=\"\(HTMLEscaping.attribute(value))\"" }
            output += ">"

            switch name {
            case "br": text += "\n"
            case "li": newline(); text += "• "
            case "img":
                if let alt = attributes.first(where: { $0.0 == "alt" })?.1, !alt.isEmpty { text += "[\(alt)]" }
            case "td", "th": text += "\t"
            case "pre": newline(); preDepth += 1
            case "a": linkStack.append(kept.first { $0.0 == "href" }?.1)
            default: if OutgoingHTMLSanitizer.blockElements.contains(name) { newline() }
            }
            if !OutgoingHTMLSanitizer.voidElements.contains(name) { stack.append(name) }
        }

        mutating func endTag(_ name: String) {
            guard let index = stack.lastIndex(of: name) else { return }
            for open in stack[index...].reversed() {
                output += "</\(open)>"
                closedForText(open)
            }
            stack.removeSubrange(index...)
        }

        mutating func closedForText(_ name: String) {
            if name == "pre" { preDepth = max(0, preDepth - 1) }
            if name == "a", let href = linkStack.popLast() ?? nil {
                let shown = href.hasPrefix("mailto:") ? String(href.dropFirst(7)) : href
                if !text.hasSuffix(shown) { text += " <\(href)>" }
            }
            if OutgoingHTMLSanitizer.blockElements.contains(name) { newline() }
        }

        /// The parsing rules that matter for re-serialisation: a block closes an open <p>, an <li> closes the
        /// previous <li>, table cells and rows close their siblings, and links don't nest. Without them our output
        /// would nest what the original parser treated as siblings.
        mutating func implicitlyClose(before name: String) {
            func closeIfOpen(_ target: Set<String>, stoppingAt boundaries: Set<String>) {
                for open in stack.reversed() {
                    if boundaries.contains(open) { return }
                    if target.contains(open) {
                        endTag(open)
                        return
                    }
                }
            }
            if OutgoingHTMLSanitizer.blockElements.contains(name) {
                closeIfOpen(["p"], stoppingAt: ["td", "th", "li", "blockquote", "div", "table"])
            }
            switch name {
            case "li": closeIfOpen(["li"], stoppingAt: ["ul", "ol"])
            case "dt", "dd": closeIfOpen(["dt", "dd"], stoppingAt: ["dl"])
            case "tr": closeIfOpen(["tr"], stoppingAt: ["table", "tbody", "thead", "tfoot"])
            case "td", "th": closeIfOpen(["td", "th"], stoppingAt: ["tr", "table"])
            case "a": closeIfOpen(["a"], stoppingAt: [])
            default: break
            }
        }

        /// The index after the end tag that closes `name`, counting nested elements of the same name.
        func matchingEnd(of name: String, from start: Int) -> Int? {
            var depth = 1
            var cursor = start
            while let lessThan = find("<", from: cursor) {
                var index = lessThan + 1
                let isEnd = index < source.count && source[index] == UInt8(ascii: "/")
                if isEnd { index += 1 }
                let nameStart = index
                while index < source.count, isLetter(source[index]) || isDigit(source[index]) { index += 1 }
                let tagName = String(decoding: source[nameStart..<index], as: UTF8.self).lowercased()
                guard let greaterThan = find(">", from: index) else { return nil }
                if tagName == name {
                    let selfClosing = source[greaterThan - 1] == UInt8(ascii: "/")
                    if isEnd { depth -= 1 } else if !selfClosing { depth += 1 }
                    if depth == 0 { return greaterThan + 1 }
                }
                cursor = greaterThan + 1
            }
            return nil
        }

        // MARK: Attribute values

        /// Browsers drop tabs and line breaks anywhere in a URL and ignore leading and trailing controls, so
        /// "jav&#x09;ascript:" must be judged as "javascript:".
        func safeLink(_ value: String) -> String? {
            let scalars = value.unicodeScalars
                .drop { $0.value <= 0x20 }
                .filter { !($0.value < 0x20 || $0.value == 0x7F) }
            let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "%20")
            guard let url = URL(string: cleaned), let scheme = url.scheme?.lowercased(),
                  OutgoingHTMLSanitizer.linkSchemes.contains(scheme)
            else { return nil }
            return (options.cleansLinks ? LinkCleaner.clean(url) : url).absoluteString
        }

        mutating func imageSource(_ value: String, attributes: [(String, String)]) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("cid:") {
                let id = String(trimmed.dropFirst(4))
                let cid = id.removingPercentEncoding ?? id
                guard !cid.isEmpty else { return nil }
                if !contentIDs.contains(cid) { contentIDs.append(cid) }
                return trimmed
            }
            if lower.hasPrefix("data:") {
                let isImage = OutgoingHTMLSanitizer.dataImageTypes.contains { type in
                    lower.hasPrefix(type + ";") || lower.hasPrefix(type + ",")
                }
                guard isImage, Self.decodedSize(ofDataURL: trimmed) <= options.maxDataImageBytes else { return nil }
                return trimmed
            }
            var source = trimmed
            if source.hasPrefix("//") { source = "https:" + source }
            guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            let byName = Dictionary(attributes, uniquingKeysWith: { first, _ in first })
            if TrackerList.isTracker(url) || MessageRenderer.isInvisible(byName) {
                trackers += 1
                return nil
            }
            if options.remoteImages == .remove {
                remoteImagesRemoved += 1
                return nil
            }
            return url.absoluteString
        }

        static func decodedSize(ofDataURL url: String) -> Int {
            guard let comma = url.firstIndex(of: ",") else { return url.utf8.count }
            let payload = url[url.index(after: comma)...]
            let isBase64 = url[..<comma].lowercased().hasSuffix(";base64")
            return isBase64 ? payload.utf8.count / 4 * 3 : payload.utf8.count
        }

        func filterStyle(_ style: String) -> String {
            var kept: [String] = []
            for declaration in style.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let property = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let squashed = value.lowercased().filter { !$0.isWhitespace }
                guard OutgoingHTMLSanitizer.cssProperties.contains(property), !value.isEmpty,
                      !squashed.contains("url("), !squashed.contains("expression("),
                      !squashed.contains("javascript:"), !squashed.contains("image-set("),
                      !squashed.contains("@import"), !value.contains("\\"), !value.contains("<"),
                      !value.contains("/*"), value.count <= 300
                else { continue }
                if property == "display", !OutgoingHTMLSanitizer.displayValues.contains(squashed) { continue }
                kept.append("\(property): \(value)")
            }
            return kept.joined(separator: "; ")
        }

        // MARK: Text

        mutating func emitText(_ bytes: ArraySlice<UInt8>) {
            let decoded = Entities.decode(String(decoding: bytes, as: UTF8.self))
            output += HTMLEscaping.text(decoded)
            if preDepth > 0 {
                text += decoded
            } else {
                let collapsed = decoded.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
                if collapsed == " " && (text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ")) { return }
                text += (text.isEmpty || text.hasSuffix("\n")) ? String(collapsed.drop { $0 == " " }) : collapsed
            }
        }

        mutating func newline() {
            while text.hasSuffix(" ") { text.removeLast() }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        }

        func plainText() -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: Scanning helpers

        func starts(with string: String) -> Bool {
            let bytes = Array(string.utf8)
            guard position + bytes.count <= source.count else { return false }
            return Array(source[position..<position + bytes.count]) == bytes
        }

        func find(_ string: String, from start: Int) -> Int? {
            let bytes = Array(string.utf8)
            guard !bytes.isEmpty, start < source.count else { return nil }
            var index = start
            while index + bytes.count <= source.count {
                if source[index] == bytes[0], Array(source[index..<index + bytes.count]) == bytes { return index }
                index += 1
            }
            return nil
        }

        func findCaseInsensitive(_ string: String, from start: Int) -> Int? {
            let bytes = Array(string.lowercased().utf8)
            var index = start
            while index + bytes.count <= source.count {
                var match = true
                for (offset, byte) in bytes.enumerated() where lower(source[index + offset]) != byte {
                    match = false
                    break
                }
                if match { return index }
                index += 1
            }
            return nil
        }

        func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
        func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
        }
    }
}

/// Escaping for HTML this package writes itself.
package enum HTMLEscaping {
    package static func text(_ value: String) -> String {
        guard value.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" }) else { return value }
        return value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    package static func attribute(_ value: String) -> String {
        text(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// HTML character references: numeric ones and the named ones that matter in mail.
package enum Entities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "bull": "•", "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°",
        "times": "×", "divide": "÷", "laquo": "«", "raquo": "»", "auml": "ä", "ouml": "ö", "uuml": "ü",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "aacute": "á",
        "agrave": "à", "ccedil": "ç", "ntilde": "ñ", "oslash": "ø", "aring": "å", "aelig": "æ",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{00AD}", "tab": "\t", "newline": "\n",
    ]

    package static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var output = ""
        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            guard character == "&", let semicolon = string[index...].prefix(40).firstIndex(of: ";") else {
                output.append(character)
                index = string.index(after: index)
                continue
            }
            let name = string[string.index(after: index)..<semicolon]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = named[String(name)]
            }
            if let replacement {
                output += replacement
                index = string.index(after: semicolon)
            } else {
                output.append(character)
                index = string.index(after: index)
            }
        }
        return output
    }
}
