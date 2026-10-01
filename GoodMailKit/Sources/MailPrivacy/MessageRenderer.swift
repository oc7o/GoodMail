import Foundation

public struct MessagePart: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case html, plainText }

    public var kind: Kind
    public var content: String

    public init(kind: Kind, content: String) {
        self.kind = kind
        self.content = content
    }
}

public enum RemoteContentPolicy: Sendable, Equatable {
    /// Nothing is fetched from the network.
    case blockAll
    /// Images load over HTTPS; trackers stay blocked.
    case allowImages
}

public struct RenderedMessage: Sendable, Equatable {
    /// A complete HTML document that is safe to hand to a web view.
    public let html: String
    /// Remote images the message references, not counting trackers.
    public let remoteImageCount: Int
    /// Tracking pixels and known tracker images, which are removed under every policy.
    public let trackerCount: Int
    /// Styled HTML mail is written for a white page, so it is not adapted to dark mode.
    public let isStyled: Bool
}

/// Turns message bodies into a self-contained HTML document that cannot phone home.
///
/// The Content-Security-Policy is the enforcement; removing trackers from the markup on top of it
/// keeps them blocked once the user allows images.
public enum MessageRenderer {
    public static func render(_ parts: [MessagePart], policy: RemoteContentPolicy) -> RenderedMessage {
        var body = ""
        var remoteImages = 0
        var trackers = 0
        for part in parts {
            switch part.kind {
            case .html:
                let sanitized = sanitize(part.content)
                body += "<div>\(sanitized.html)</div>"
                remoteImages += sanitized.remoteImages
                trackers += sanitized.trackers
            case .plainText:
                body += "<div class=\"gm-plain\">\(linkify(part.content))</div>"
            }
        }

        let isStyled = parts.contains { $0.kind == .html }
        let html = """
            <!doctype html><html><head><meta charset="utf-8">\
            <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(policy))">\
            <meta name="viewport" content="width=device-width, initial-scale=1">\
            <meta name="color-scheme" content="\(isStyled ? "light" : "light dark")">\
            <style>\(baseStyle)\(isStyled ? styledPageStyle : "")</style></head><body>\(body)</body></html>
            """
        return RenderedMessage(html: html, remoteImageCount: remoteImages, trackerCount: trackers, isStyled: isStyled)
    }

    static func contentSecurityPolicy(_ policy: RemoteContentPolicy) -> String {
        let images = policy == .allowImages ? "data: cid: https:" : "data: cid:"
        return "default-src 'none'; style-src 'unsafe-inline'; img-src \(images); font-src data:; form-action 'none'"
    }

    static let baseStyle = """
        html, body { margin: 0; padding: 0; }
        body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; \
        overflow-wrap: break-word; -webkit-text-size-adjust: 100%; padding: 12px; }
        img { max-width: 100%; height: auto; }
        blockquote { margin: 0 0 0 0.6em; padding-left: 0.8em; border-left: 2px solid rgba(128, 128, 128, 0.4); }
        .gm-plain { white-space: pre-wrap; }
        """

    /// The web view itself is transparent, so styled mail brings its own white page.
    static let styledPageStyle = "html { background: #fff; color: #000; }"

    // MARK: HTML

    struct Sanitized: Equatable {
        var html: String
        var remoteImages = 0
        var trackers = 0
    }

    static func sanitize(_ html: String) -> Sanitized {
        var result = Sanitized(html: html)
        // Scripts never run and remote stylesheets never load, but <link> can also trigger DNS prefetches
        // and <meta http-equiv> can redirect, neither of which the CSP covers.
        for pattern in [scriptElement, linkOrBaseTag, metaHTTPEquivTag] {
            result.html = pattern.stringByReplacingMatches(
                in: result.html, range: NSRange(result.html.startIndex..., in: result.html), withTemplate: "")
        }

        let source = result.html
        var output = ""
        var cursor = source.startIndex
        for match in imageTag.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            output += source[cursor..<range.lowerBound]
            cursor = range.upperBound

            let tag = String(source[range])
            let attributes = attributes(of: tag)
            guard let url = remoteURL(attributes["src"]) else {
                output += tag
                continue
            }
            if TrackerList.isTracker(url) || isInvisible(attributes) {
                result.trackers += 1
            } else {
                result.remoteImages += 1
                output += tag
            }
        }
        output += source[cursor...]
        result.html = output
        return result
    }

    static func attributes(of tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag) }.first
            attributes[tag[name].lowercased()] = value.map { String(tag[$0]) } ?? ""
        }
        return attributes
    }

    static func remoteURL(_ source: String?) -> URL? {
        guard var source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else { return nil }
        if source.hasPrefix("//") { source = "https:" + source }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Images that are at most one pixel in every stated dimension, or hidden by their own style.
    static func isInvisible(_ attributes: [String: String]) -> Bool {
        let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
        if style.contains("display:none") || style.contains("visibility:hidden") || style.contains("opacity:0;")
            || style.hasSuffix("opacity:0") {
            return true
        }
        let dimensions = ["width", "height"].compactMap { name in
            pixels(attributes[name]) ?? pixels(styleValue(name, in: style))
        }
        return !dimensions.isEmpty && dimensions.allSatisfy { $0 <= 1 }
    }

    private static func pixels(_ value: String?) -> Double? {
        guard var value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        if value.hasSuffix("px") { value.removeLast(2) }
        return Double(value)
    }

    private static func styleValue(_ property: String, in style: String) -> String? {
        for declaration in style.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0] == property { return String(pair[1]) }
        }
        return nil
    }

    // MARK: Plain text

    static func linkify(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        for match in webLink.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard var range = Range(match.range, in: text) else { continue }
            while let last = text[range].last, ".,;:!?)]}>'\"".contains(last) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            guard !range.isEmpty else { continue }
            let link = escape(String(text[range]))
            output += escape(String(text[cursor..<range.lowerBound]))
            output += "<a href=\"\(link)\">\(link)</a>"
            cursor = range.upperBound
        }
        return output + escape(String(text[cursor...]))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let scriptElement = regex(#"<script\b.*?(</script\s*>|\z)"#)
    private static let linkOrBaseTag = regex(#"<(link|base)\b[^>]*>"#)
    private static let metaHTTPEquivTag = regex(#"<meta\b[^>]*\bhttp-equiv\b[^>]*>"#)
    private static let imageTag = regex(#"<img\b[^>]*>"#)
    private static let attribute = regex(#"([a-z][a-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let webLink = regex(#"https?://[^\s<>"]+"#)
}
