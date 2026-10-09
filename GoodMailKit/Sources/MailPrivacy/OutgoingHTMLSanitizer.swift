import Foundation

/// Re-serialises untrusted HTML (a quoted original, an HTML signature, a draft written elsewhere) through an
/// allowlist, for HTML that leaves the device or is read back into the composer.
///
/// It parses loosely and emits strictly: input is tokenised forgivingly, but the output contains only allowlisted
/// elements and attributes, every text node and attribute value is re-escaped, and tags are balanced by our own
/// stack. A mis-parse therefore costs fidelity, never safety. Every step is linear in the input, so a hostile
/// original of several megabytes can't stall a send.
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
        /// Where `html` first lacks something the original showed, for each kind of loss, as a UTF-8 offset into
        /// `html`: inside the start tag of the element that lost a link target or a style, or where removed content
        /// was. A caller that only cares about part of the document compares offsets.
        package var firstLoss: [Loss: Int] = [:]

        /// The kinds of loss at or before `offset`.
        package func losses(through offset: Int) -> Set<Loss> {
            Set(firstLoss.filter { $0.value <= offset }.keys)
        }
    }

    /// What the sanitizer can take away beyond what a reader of its output can see: an image, or anything else
    /// that changes how the text looks (removed elements, link targets, styles and style sheets).
    package enum Loss: Sendable, Hashable {
        case image
        case content
    }

    public static func sanitize(_ html: String, options: Options = Options()) -> Result {
        var state = State(source: Array(html.utf8), options: options)
        state.run()
        return Result(
            html: String(decoding: state.output, as: UTF8.self), contentIDs: state.contentIDs,
            removedTrackers: state.trackers, removedRemoteImages: state.remoteImagesRemoved, text: state.plainText(),
            firstLoss: state.firstLoss)
    }

    // MARK: Allowlists

    static let allowedElements: Set<String> = [
        "a", "abbr", "address", "b", "bdi", "bdo", "big", "blockquote", "br", "caption", "center", "cite", "code",
        "col", "colgroup", "dd", "del", "dfn", "div", "dl", "dt", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "s", "samp", "small", "span", "strike",
        "strong", "sub", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var", "wbr",
    ]
    /// Elements outside the allowlist that browsers lay out as blocks. They are written as the allowed element
    /// that looks the same, so their text doesn't run into its neighbours.
    static let blockSubstitutes: [String: String] = [
        "article": "div", "aside": "div", "details": "div", "fieldset": "div", "figcaption": "div", "figure": "div",
        "footer": "div", "form": "div", "header": "div", "hgroup": "div", "legend": "div", "main": "div",
        "nav": "div", "search": "div", "section": "div", "summary": "div", "dir": "ul", "menu": "ul",
    ]
    /// Dropped together with everything inside them.
    static let droppedWithContent: Set<String> = [
        "script", "style", "title", "textarea", "iframe", "object", "embed", "applet", "frame", "frameset",
        "noscript", "noembed", "noframes", "template", "svg", "math", "canvas", "audio", "video", "select",
        "button", "xmp", "plaintext",
    ]
    /// Dropped elements whose content a browser doesn't show anyway; dropping any other one loses something.
    static let unrendered: Set<String> = ["script", "style", "title", "template", "noembed", "noframes"]
    /// Their content is never markup, so it is skipped up to the matching end tag without tokenising it.
    static let rawText: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "noscript", "noembed", "noframes", "iframe", "plaintext",
    ]
    package static let voidElements: Set<String> = [
        "br", "hr", "img", "wbr", "col", "input", "meta", "link", "base", "source", "area", "param", "track", "embed",
        "frame",
    ]
    /// Elements nested deeper are unwrapped, which bounds the nesting of what we send.
    static let maximumDepth = 256
    /// Style sheets beyond this size aren't examined; they count as changing everything.
    static let maximumStyleSheetBytes = 256 * 1024

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
        "ol": ["start", "type", "reversed"], "ul": ["type"], "li": ["value"],
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
        "max-height", "display", "list-style", "list-style-type", "list-style-position", "table-layout",
        "overflow-wrap", "word-break", "word-wrap", "float", "clear", "visibility", "opacity", "overflow",
        "overflow-x", "overflow-y",
    ]
    static let displayValues: Set<String> = [
        "block", "inline", "inline-block", "none", "table", "table-row", "table-cell", "list-item",
    ]
    /// Declarations whose loss doesn't change how text looks: interaction, printing, rendering hints. Vendor
    /// (`-webkit-`) and Outlook (`mso-`) extensions count too.
    static let neutralCSSProperties: Set<String> = [
        "cursor", "pointer-events", "user-select", "caret-color", "outline", "outline-color", "outline-style",
        "outline-width", "outline-offset", "resize", "touch-action", "scroll-behavior", "will-change", "transition",
        "transition-property", "transition-duration", "transition-delay", "transition-timing-function", "orphans",
        "widows", "page-break-before", "page-break-after", "page-break-inside", "break-before", "break-after",
        "break-inside", "line-break", "text-size-adjust", "text-rendering", "font-kerning", "font-smoothing",
        "speak", "color-scheme", "print-color-adjust", "forced-color-adjust", "image-rendering",
    ]
    static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    static let dataImageTypes = [
        "data:image/png", "data:image/gif", "data:image/jpeg", "data:image/jpg", "data:image/webp",
    ]

    static func isNeutral(property: String) -> Bool {
        property.hasPrefix("-") || property.hasPrefix("mso-") || neutralCSSProperties.contains(property)
    }

    // MARK: Tokeniser and emitter

    struct State {
        let source: [UInt8]
        let options: Options
        var position = 0
        var output: [UInt8] = []
        var stack: [String] = []
        /// Where each open element is in `stack`, so closing or finding one never searches the stack.
        var openIndices: [String: [Int]] = [:]
        var contentIDs: [String] = []
        var knownContentIDs: Set<String> = []
        var trackers = 0
        var remoteImagesRemoved = 0
        var text: [UInt8] = []
        var preDepth = 0
        var linkStack: [String?] = []
        /// Elements unwrapped below `maximumDepth`, so their end tags are skipped too.
        var unwrapped: [String] = []
        /// Dropped elements whose end tag the rest of the document lacks; their next start tags need no search.
        var unclosed: Set<String> = []
        var firstLoss: [Loss: Int] = [:]
        var styleSheets = ""
        var reach = StyleSheetReach()

        init(source: [UInt8], options: Options) {
            self.source = source
            self.options = options
            output.reserveCapacity(source.count)
        }

        mutating func run() {
            var textStart = 0
            while position < source.count {
                guard source[position] == Byte.lessThan, isMarkup(at: position) else {
                    position += 1
                    continue
                }
                if textStart < position { emitText(source[textStart..<position]) }
                position = consumeMarkup()
                textStart = position
            }
            if textStart < source.count { emitText(source[textStart...]) }
            close(downTo: 0)
            if !styleSheets.isEmpty, let offset = reach.firstAffected(by: styleSheets) { lose(.content, at: offset) }
        }

        /// Whether the "<" at `index` starts a tag, comment or declaration; otherwise it is text.
        func isMarkup(at index: Int) -> Bool {
            let next = index + 1
            guard next < source.count else { return false }
            switch source[next] {
            case Byte.exclamationMark, Byte.questionMark: return true
            case Byte.slash: return next + 1 < source.count && isLetter(source[next + 1])
            default: return isLetter(source[next])
            }
        }

        /// Consumes the markup construct at `position`; returns the index after it.
        mutating func consumeMarkup() -> Int {
            let next = position + 1
            if matches(Byte.commentOpen, at: position) {
                return find(Byte.commentClose, from: position + 4).map { $0 + 3 } ?? source.count
            }
            if source[next] == Byte.exclamationMark || source[next] == Byte.questionMark {
                return source[next...].firstIndex(of: Byte.greaterThan).map { $0 + 1 } ?? source.count
            }
            let isEnd = source[next] == Byte.slash
            var cursor = isEnd ? next + 1 : next
            let nameStart = cursor
            while cursor < source.count, !isSpace(source[cursor]), source[cursor] != Byte.greaterThan,
                  source[cursor] != Byte.slash {
                cursor += 1
            }
            let name = String(decoding: source[nameStart..<cursor], as: UTF8.self).lowercased()
            var attributes: [(String, String)] = []
            while cursor < source.count, source[cursor] != Byte.greaterThan {
                if isSpace(source[cursor]) || source[cursor] == Byte.slash {
                    cursor += 1
                    continue
                }
                let attributeStart = cursor
                while cursor < source.count, !isSpace(source[cursor]), source[cursor] != Byte.equals,
                      source[cursor] != Byte.greaterThan,
                      !(source[cursor] == Byte.slash && cursor > attributeStart) {
                    cursor += 1
                }
                let attributeName = String(decoding: source[attributeStart..<cursor], as: UTF8.self).lowercased()
                while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
                var value: ArraySlice<UInt8> = []
                if cursor < source.count, source[cursor] == Byte.equals {
                    cursor += 1
                    while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
                    if cursor < source.count, source[cursor] == Byte.quote || source[cursor] == Byte.apostrophe {
                        let quote = source[cursor]
                        let valueStart = cursor + 1
                        cursor = source[valueStart...].firstIndex(of: quote) ?? source.count
                        value = source[valueStart..<cursor]
                        cursor += 1
                    } else {
                        let valueStart = cursor
                        while cursor < source.count, !isSpace(source[cursor]), source[cursor] != Byte.greaterThan {
                            cursor += 1
                        }
                        value = source[valueStart..<cursor]
                    }
                }
                if !attributeName.isEmpty {
                    var decoded: [UInt8] = []
                    Entities.decode(value, inAttribute: true, into: &decoded)
                    attributes.append((attributeName, String(decoding: decoded, as: UTF8.self)))
                }
            }
            let selfClosing = cursor > 0 && cursor < source.count && source[cursor - 1] == Byte.slash
            let after = min(cursor + 1, source.count)
            if isEnd {
                let element = OutgoingHTMLSanitizer.blockSubstitutes[name] ?? name
                if unwrapped.last == element {
                    unwrapped.removeLast()
                } else if element == "br" {
                    startTag(element, []) // browsers treat </br> as <br>
                } else {
                    endTag(element)
                }
                return after
            }
            if OutgoingHTMLSanitizer.rawText.contains(name) {
                let end = findCaseInsensitive("</\(name)", from: after) ?? source.count
                if name == "style" {
                    noteStyleSheet(source[after..<end])
                } else if !OutgoingHTMLSanitizer.unrendered.contains(name) {
                    lose(.content, at: output.count)
                }
                return source[end...].firstIndex(of: Byte.greaterThan).map { $0 + 1 } ?? source.count
            }
            if OutgoingHTMLSanitizer.droppedWithContent.contains(name) {
                if !OutgoingHTMLSanitizer.unrendered.contains(name) { lose(.content, at: output.count) }
                if selfClosing || unclosed.contains(name) || OutgoingHTMLSanitizer.voidElements.contains(name) {
                    return after
                }
                if let end = matchingEnd(of: name, from: after) { return end }
                unclosed.insert(name)
                return after
            }
            startTag(name, attributes)
            return after
        }

        // MARK: Elements

        mutating func startTag(_ name: String, _ attributes: [(String, String)]) {
            let start = output.count
            let element = OutgoingHTMLSanitizer.blockSubstitutes[name] ?? name
            let isAllowed = OutgoingHTMLSanitizer.allowedElements.contains(element)
            let isVoid = OutgoingHTMLSanitizer.voidElements.contains(element)
            // Checked before anything else, so an element past the depth limit costs constant time.
            let isUnwrapped = !isAllowed
                || (!isVoid && (stack.count >= OutgoingHTMLSanitizer.maximumDepth || !unwrapped.isEmpty))
            noteForStyleSheets(name, attributes, at: isUnwrapped ? start : start + 1)
            if isUnwrapped {
                if isAllowed {
                    unwrapped.append(element)
                    lose(.content, at: start)
                } else if name == "html" || name == "body" {
                    noteDocumentAttributes(attributes, at: start)
                } else if Self.rendersSomething(name, attributes) {
                    lose(.content, at: start)
                }
                return
            }
            implicitlyClose(before: element)

            var kept: [(String, String)] = []
            var lost: Set<Loss> = []
            var seen: Set<String> = [] // a browser uses the first of repeated attributes
            for (attribute, value) in attributes where seen.insert(attribute).inserted {
                if attribute == "class" {
                    let classes = value.split(whereSeparator: \.isWhitespace).map(String.init)
                        .filter(options.allowedClasses.contains)
                    if !classes.isEmpty { kept.append((attribute, classes.joined(separator: " "))) }
                    continue
                }
                if attribute == "background" { lost.insert(.image) }
                guard OutgoingHTMLSanitizer.globalAttributes.contains(attribute)
                        || OutgoingHTMLSanitizer.elementAttributes[element]?.contains(attribute) == true
                else { continue }
                switch attribute {
                case "href":
                    if let href = safeLink(value) {
                        kept.append((attribute, href))
                    } else if !value.allSatisfy(\.isWhitespace) {
                        lost.insert(.content)
                    }
                case "src":
                    guard let src = imageSource(value, attributes: attributes) else {
                        lose(.image, at: start)
                        return // drops the img
                    }
                    kept.append((attribute, src))
                case "style":
                    let style = filterStyle(value)
                    if !style.kept.isEmpty { kept.append((attribute, style.kept)) }
                    if !style.isComplete { lost.insert(.content) }
                case "bgcolor", "color":
                    if Self.isSimpleColor(value) { kept.append((attribute, value)) } else { lost.insert(.content) }
                default:
                    if value.count <= 200 { kept.append((attribute, value)) }
                }
            }
            if attributes.contains(where: { $0.0 == "hidden" }) {
                // The attribute isn't allowlisted, but what it does is: keep the element hidden.
                if let index = kept.firstIndex(where: { $0.0 == "style" }) {
                    kept[index].1 += "; display: none"
                } else {
                    kept.append(("style", "display: none"))
                }
            }
            if element == "img", !kept.contains(where: { $0.0 == "src" }) {
                lose(.image, at: start)
                return
            }
            emit("<\(element)")
            for (attribute, value) in kept { emit(" \(attribute)=\"\(HTMLEscaping.attribute(value))\"") }
            emit(">")
            for loss in lost { lose(loss, at: start + 1) }

            switch element {
            case "br": text.append(Byte.lineFeed)
            case "li":
                newline()
                text.append(contentsOf: "• ".utf8)
            case "img":
                if let alt = attributes.first(where: { $0.0 == "alt" })?.1, !alt.isEmpty {
                    text.append(contentsOf: "[\(alt)]".utf8)
                }
            case "td", "th": text.append(Byte.tab)
            case "pre":
                newline()
                preDepth += 1
            case "a": linkStack.append(kept.first { $0.0 == "href" }?.1)
            default: if OutgoingHTMLSanitizer.blockElements.contains(element) { newline() }
            }
            if !isVoid {
                openIndices[element, default: []].append(stack.count)
                stack.append(element)
            }
        }

        mutating func endTag(_ name: String) {
            guard let index = openIndices[name]?.last else { return }
            close(downTo: index)
        }

        /// Closes every open element from the top of the stack down to `index`.
        mutating func close(downTo index: Int) {
            while stack.count > index {
                let open = stack.removeLast()
                openIndices[open]?.removeLast()
                emit("</\(open)>")
                closedForText(open)
            }
        }

        mutating func closedForText(_ name: String) {
            if name == "pre" { preDepth = max(0, preDepth - 1) }
            if name == "a", let href = linkStack.popLast() ?? nil {
                let shown = href.hasPrefix("mailto:") ? String(href.dropFirst(7)) : href
                if !text.ends(with: shown.utf8) { text.append(contentsOf: " <\(href)>".utf8) }
            }
            if OutgoingHTMLSanitizer.blockElements.contains(name) { newline() }
        }

        /// The parsing rules that matter for re-serialisation: a block closes an open <p>, an <li> closes the
        /// previous <li>, table cells and rows close their siblings, and links don't nest. Without them our output
        /// would nest what the original parser treated as siblings.
        mutating func implicitlyClose(before name: String) {
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

        /// Closes the innermost open element of `targets` unless one of `boundaries` is open inside it.
        mutating func closeIfOpen(_ targets: [String], stoppingAt boundaries: [String]) {
            var target = -1
            for name in targets { target = max(target, openIndices[name]?.last ?? -1) }
            guard target >= 0 else { return }
            for name in boundaries where openIndices[name]?.last ?? -1 > target { return }
            close(downTo: target)
        }

        /// The index after the end tag that closes `name`, counting nested elements of the same name.
        func matchingEnd(of name: String, from start: Int) -> Int? {
            var depth = 1
            var cursor = start
            while let lessThan = source[min(cursor, source.count)...].firstIndex(of: Byte.lessThan) {
                var index = lessThan + 1
                let isEnd = index < source.count && source[index] == Byte.slash
                if isEnd { index += 1 }
                let nameStart = index
                while index < source.count, isLetter(source[index]) || isDigit(source[index]) { index += 1 }
                guard let greaterThan = source[index...].firstIndex(of: Byte.greaterThan) else { return nil }
                if index - nameStart == name.utf8.count,
                   String(decoding: source[nameStart..<index], as: UTF8.self).lowercased() == name {
                    let selfClosing = source[greaterThan - 1] == Byte.slash
                    if isEnd { depth -= 1 } else if !selfClosing { depth += 1 }
                    if depth == 0 { return greaterThan + 1 }
                }
                cursor = greaterThan + 1
            }
            return nil
        }

        // MARK: Losses

        mutating func lose(_ loss: Loss, at offset: Int) {
            firstLoss[loss] = min(firstLoss[loss] ?? offset, offset)
        }

        mutating func noteForStyleSheets(_ name: String, _ attributes: [(String, String)], at offset: Int) {
            let classes = attributes.first { $0.0 == "class" }?.1.split(whereSeparator: \.isWhitespace) ?? []
            reach.record(element: name, classes: classes, id: attributes.first { $0.0 == "id" }?.1, at: offset)
        }

        mutating func noteStyleSheet(_ bytes: ArraySlice<UInt8>) {
            guard styleSheets.utf8.count + bytes.count <= OutgoingHTMLSanitizer.maximumStyleSheetBytes else {
                lose(.content, at: 0)
                return
            }
            styleSheets += String(decoding: bytes, as: UTF8.self) + "\n"
        }

        /// <html> and <body> are unwrapped; colours, fonts and backgrounds they set for the whole document go with
        /// them. Margins and wrapping rules don't change the text.
        mutating func noteDocumentAttributes(_ attributes: [(String, String)], at offset: Int) {
            for (name, value) in attributes {
                let squashed = value.lowercased().filter { !$0.isWhitespace }
                switch name {
                case "background": lose(.image, at: offset)
                case "bgcolor": if !Self.white.contains(squashed) { lose(.content, at: offset) }
                case "text": if !Self.black.contains(squashed) { lose(.content, at: offset) }
                case "link", "vlink", "alink": lose(.content, at: offset)
                case "style":
                    for (property, value) in Self.declarations(value) where !Self.isNeutralForDocument(property, value) {
                        lose(.content, at: offset)
                    }
                default: break
                }
            }
        }

        /// Whether an element we unwrap showed something of its own: a form field, hidden content (now shown), or
        /// a style (now gone).
        static func rendersSomething(_ name: String, _ attributes: [(String, String)]) -> Bool {
            if name == "input" { return attributes.first { $0.0 == "type" }?.1.lowercased() != "hidden" }
            return attributes.contains { attribute, value in
                attribute == "hidden"
                    || (attribute == "style" && declarations(value).contains { !OutgoingHTMLSanitizer.isNeutral(property: $0.property) })
            }
        }

        static let white: Set<String> = ["#fff", "#ffffff", "white", "rgb(255,255,255)", "transparent"]
        static let black: Set<String> = ["#000", "#000000", "black", "rgb(0,0,0)", "windowtext"]

        static func isNeutralForDocument(_ property: String, _ value: String) -> Bool {
            let squashed = value.lowercased().filter { !$0.isWhitespace }
            return OutgoingHTMLSanitizer.isNeutral(property: property) || property.hasPrefix("margin")
                || property.hasPrefix("padding") || ["overflow-wrap", "word-wrap", "word-break"].contains(property)
                || (["background", "background-color"].contains(property) && white.contains(squashed))
                || (property == "color" && black.contains(squashed))
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
                if knownContentIDs.insert(cid).inserted { contentIDs.append(cid) }
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

        /// A colour name or hex value: "#336699", "red".
        static func isSimpleColor(_ value: String) -> Bool {
            let digits = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
            return (1...20).contains(digits.count) && digits.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        static func declarations(_ style: String) -> [(property: String, value: String)] {
            style.split(separator: ";").compactMap { declaration in
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                let property = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : (property, value)
            }
        }

        /// The declarations we keep, and whether those are all that changed how the element looks.
        func filterStyle(_ style: String) -> (kept: String, isComplete: Bool) {
            var kept: [String] = []
            var isComplete = true
            for (property, value) in Self.declarations(style) {
                let squashed = value.lowercased().filter { !$0.isWhitespace }
                guard OutgoingHTMLSanitizer.cssProperties.contains(property),
                      !squashed.contains("url("), !squashed.contains("expression("),
                      !squashed.contains("javascript:"), !squashed.contains("image-set("),
                      !squashed.contains("@import"), !value.contains("\\"), !value.contains("<"),
                      !value.contains("/*"), value.count <= 300,
                      property != "display" || OutgoingHTMLSanitizer.displayValues.contains(squashed)
                else {
                    if !OutgoingHTMLSanitizer.isNeutral(property: property) { isComplete = false }
                    continue
                }
                kept.append("\(property): \(value)")
            }
            return (kept.joined(separator: "; "), isComplete)
        }

        // MARK: Text

        mutating func emitText(_ bytes: ArraySlice<UInt8>) {
            var decoded: [UInt8] = []
            decoded.reserveCapacity(bytes.count)
            Entities.decode(bytes, inAttribute: false, into: &decoded)
            HTMLEscaping.appendText(decoded, to: &output)
            if preDepth > 0 {
                text.append(contentsOf: decoded)
                return
            }
            // HTML's whitespace collapses to one space, and to nothing at the start of a line.
            var pendingSpace = false
            for byte in decoded {
                if isSpace(byte) {
                    pendingSpace = true
                    continue
                }
                if pendingSpace { appendSpace() }
                pendingSpace = false
                text.append(byte)
            }
            if pendingSpace { appendSpace() }
        }

        mutating func appendSpace() {
            if let last = text.last, last != Byte.space, last != Byte.lineFeed { text.append(Byte.space) }
        }

        mutating func newline() {
            while text.last == Byte.space { text.removeLast() }
            if let last = text.last, last != Byte.lineFeed { text.append(Byte.lineFeed) }
        }

        func plainText() -> String {
            String(decoding: text, as: UTF8.self).replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func emit(_ string: String) {
            output.append(contentsOf: string.utf8)
        }

        // MARK: Scanning helpers

        func matches(_ bytes: [UInt8], at index: Int) -> Bool {
            guard index + bytes.count <= source.count else { return false }
            for offset in bytes.indices where source[index + offset] != bytes[offset] { return false }
            return true
        }

        func find(_ bytes: [UInt8], from start: Int) -> Int? {
            var index = start
            while index + bytes.count <= source.count {
                if source[index] == bytes[0], matches(bytes, at: index) { return index }
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

    enum Byte {
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let exclamationMark = UInt8(ascii: "!")
        static let questionMark = UInt8(ascii: "?")
        static let equals = UInt8(ascii: "=")
        static let quote = UInt8(ascii: "\"")
        static let apostrophe = UInt8(ascii: "'")
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
        static let lineFeed = UInt8(ascii: "\n")
        static let commentOpen = Array("<!--".utf8)
        static let commentClose = Array("-->".utf8)
    }
}

extension Array where Element == UInt8 {
    func ends(with suffix: String.UTF8View) -> Bool {
        count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
    }
}

/// Escaping for HTML this package writes itself.
package enum HTMLEscaping {
    package static func text(_ value: String) -> String {
        guard value.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E }) else { return value }
        var output: [UInt8] = []
        appendText(value.utf8, to: &output)
        return String(decoding: output, as: UTF8.self)
    }

    package static func attribute(_ value: String) -> String {
        guard value.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 }) else { return value }
        var output: [UInt8] = []
        appendText(value.utf8, escapingQuotes: true, to: &output)
        return String(decoding: output, as: UTF8.self)
    }

    static func appendText(
        _ bytes: some Sequence<UInt8>, escapingQuotes: Bool = false, to output: inout [UInt8]
    ) {
        for byte in bytes {
            switch byte {
            case 0x26: output.append(contentsOf: "&amp;".utf8)
            case 0x3C: output.append(contentsOf: "&lt;".utf8)
            case 0x3E: output.append(contentsOf: "&gt;".utf8)
            case 0x22 where escapingQuotes: output.append(contentsOf: "&quot;".utf8)
            default: output.append(byte)
            }
        }
    }
}
