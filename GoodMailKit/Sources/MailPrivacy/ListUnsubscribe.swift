import Foundation

/// The ways a mailing-list message offers to unsubscribe (RFC 2369), and when one-click unsubscribe
/// (RFC 8058) can be trusted.
public enum ListUnsubscribe {
    public enum Method: Sendable, Hashable {
        /// POST `oneClickBody` to the URL (RFC 8058).
        case oneClick(URL)
        /// Send a message to the list.
        case mailto(MailtoLink)
        /// Open the list's unsubscribe page.
        case web(URL)
    }

    public static let oneClickBody = "List-Unsubscribe=One-Click"

    /// The methods in preference order: one-click, mailto, web.
    ///
    /// Each `listUnsubscribe` element is one header instance, topmost first, as JMAP's `asURLs:all` form returns
    /// it; a raw header value is parsed by RFC 2369 §2 as well. The mailto and web methods come from the last
    /// (bottom-most) instance, the one JMAP's single-instance form reports.
    ///
    /// One-click is offered only when all of these hold:
    /// - exactly one List-Unsubscribe header, holding exactly one https URL that `UnsubscribeTarget.isAllowed`;
    /// - exactly one List-Unsubscribe-Post header, whose value is `oneClickBody`;
    /// - the topmost Authentication-Results header comes from a trusted authserv-id (passed lower-cased); a
    ///   trusted id further down could have been written by anyone on the way;
    /// - one of its `dkim=pass` results pairs, by `header.d` and a `header.b` prefix of at least 8 characters,
    ///   with a DKIM-Signature whose `h=` covers both List-Unsubscribe and List-Unsubscribe-Post.
    public static func methods(
        listUnsubscribe: [[String]], listUnsubscribePost: [String], dkimSignatures: [String],
        authenticationResults: [String], isTrustedAuthServID: (String) -> Bool
    ) -> [Method] {
        var methods: [Method] = []
        if let target = oneClickTarget(
            listUnsubscribe: listUnsubscribe, listUnsubscribePost: listUnsubscribePost,
            dkimSignatures: dkimSignatures, authenticationResults: authenticationResults,
            isTrustedAuthServID: isTrustedAuthServID)
        {
            methods.append(.oneClick(target))
        }
        for method in fallbackMethods(listUnsubscribe: listUnsubscribe.last ?? []) where !methods.contains(method) {
            methods.append(method)
        }
        return methods
    }

    /// Without the headers DKIM needs (offline), only the ways that ask the user to act: mailto, then web.
    public static func fallbackMethods(listUnsubscribe: [String]) -> [Method] {
        let urls = urls(in: listUnsubscribe)
        var methods: [Method] = urls.compactMap { url in
            guard url.scheme?.lowercased() == "mailto", let link = MailtoLink(url), !link.to.isEmpty else { return nil }
            return .mailto(link)
        }
        methods += urls.compactMap { url in
            guard url.scheme?.lowercased() == "https", UnsubscribeTarget.isAllowed(url) else { return nil }
            return .web(url)
        }
        var unique: [Method] = []
        for method in methods where !unique.contains(method) { unique.append(method) }
        return unique
    }

    // MARK: List-Unsubscribe

    /// The URLs of one header instance. Parsed values stop at the first entry that isn't an absolute URL, the
    /// equivalent of RFC 2369's rule for sub-items that aren't bracketed URLs.
    static func urls(in instance: [String]) -> [URL] {
        let values = instance.count == 1 && instance[0].contains("<") ? urls(inHeaderValue: instance[0]) : instance
        var result: [URL] = []
        for value in values {
            let trimmed = value.filter { !$0.isWhitespace }
            guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else { break }
            result.append(url)
        }
        return result
    }

    /// RFC 2369 §2: a comma-separated list of `<URL>`s. A field that doesn't start with "<" is ignored, text
    /// after a URL ends the list unless a comma follows, and a sub-item that isn't a bracketed URL ends it too.
    /// Whitespace inside the brackets is ignored, as are comments between items.
    public static func urls(inHeaderValue value: String) -> [String] {
        var scanner = HeaderScanner(value.replacingOccurrences(of: "\r\n", with: ""))
        var urls: [String] = []
        while true {
            scanner.skipWhitespaceAndComments()
            guard scanner.take("<"), let url = scanner.take(upTo: ">") else { break }
            let compact = url.filter { !$0.isWhitespace }
            if !compact.isEmpty { urls.append(compact) }
            scanner.skipWhitespaceAndComments()
            guard scanner.take(",") else { break }
        }
        return urls
    }

    // MARK: One-click

    static func oneClickTarget(
        listUnsubscribe: [[String]], listUnsubscribePost: [String], dkimSignatures: [String],
        authenticationResults: [String], isTrustedAuthServID: (String) -> Bool
    ) -> URL? {
        guard listUnsubscribe.count == 1 else { return nil }
        let https = urls(in: listUnsubscribe[0]).filter { $0.scheme?.lowercased() == "https" }
        guard https.count == 1, let target = https.first, UnsubscribeTarget.isAllowed(target),
              listUnsubscribePost.count == 1,
              listUnsubscribePost[0].trimmingCharacters(in: .whitespacesAndNewlines) == oneClickBody,
              let topmost = authenticationResults.first.flatMap(AuthenticationResults.init),
              isTrustedAuthServID(topmost.authServID)
        else { return nil }
        let covering = dkimSignatures.compactMap(DKIMSignature.init).filter {
            $0.signedHeaders.contains("list-unsubscribe") && $0.signedHeaders.contains("list-unsubscribe-post")
        }
        let paired = topmost.dkimPasses.contains { result in
            result.signaturePrefix.count >= 8 && covering.contains { signature in
                signature.domain == result.domain && signature.signature.hasPrefix(result.signaturePrefix)
            }
        }
        return paired ? target : nil
    }
}

/// An Authentication-Results header (RFC 8601 §2.2), as far as one-click needs it.
struct AuthenticationResults: Equatable {
    struct DKIMPass: Equatable {
        /// `header.d`, lower-cased.
        var domain: String
        /// `header.b`: the leading characters of the signature's `b=` value (RFC 6008).
        var signaturePrefix: String
    }

    var authServID: String
    var dkimPasses: [DKIMPass]

    init?(_ value: String) {
        let segments = HeaderScanner.split(HeaderScanner.removingComments(value), at: ";")
        guard let first = segments.first?.split(whereSeparator: \.isWhitespace).first else { return nil }
        authServID = HeaderScanner.unquoted(String(first)).lowercased()
        dkimPasses = segments.dropFirst().compactMap { segment in
            let tokens = HeaderScanner.tokens(segment)
            guard let methodspec = tokens.first else { return nil }
            let method = methodspec.split(separator: "=", maxSplits: 1)
            guard method.count == 2,
                  method[0].split(separator: "/").first?.lowercased() == "dkim",
                  method[1].lowercased() == "pass"
            else { return nil }
            var properties: [String: String] = [:]
            for token in tokens.dropFirst() {
                let pair = token.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                properties[pair[0].lowercased()] = HeaderScanner.unquoted(String(pair[1]))
            }
            guard let domain = properties["header.d"], let prefix = properties["header.b"] else { return nil }
            return DKIMPass(domain: domain.lowercased(), signaturePrefix: prefix)
        }
    }
}

/// A DKIM-Signature header (RFC 6376 §3.5), as far as one-click needs it.
struct DKIMSignature: Equatable {
    /// `d=`, lower-cased.
    var domain: String
    /// `h=`, lower-cased header names.
    var signedHeaders: Set<String>
    /// `b=` without whitespace.
    var signature: String

    init?(_ value: String) {
        var tags: [String: String] = [:]
        for item in value.replacingOccurrences(of: "\r\n", with: "").split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            // Tag names are case-sensitive, and the first occurrence counts (§3.2 forbids duplicates).
            if tags[name] == nil { tags[name] = String(pair[1]) }
        }
        guard let domain = tags["d"]?.trimmingCharacters(in: .whitespaces), !domain.isEmpty,
              let headers = tags["h"], let signature = tags["b"]?.filter({ !$0.isWhitespace }), !signature.isEmpty
        else { return nil }
        self.domain = domain.lowercased()
        signedHeaders = Set(headers.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        self.signature = signature
    }
}

/// Just enough RFC 5322 lexing for structured header values: comments, quoted strings, separators.
struct HeaderScanner {
    var characters: [Character]
    var index = 0

    init(_ value: String) { characters = Array(value) }

    mutating func skipWhitespaceAndComments() {
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
            } else if characters[index] == "(" {
                skipComment()
            } else {
                return
            }
        }
    }

    mutating func skipComment() {
        var depth = 0
        while index < characters.count {
            switch characters[index] {
            case "\\": index += 1
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
            index += 1
            if depth == 0 { return }
        }
    }

    mutating func take(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    mutating func take(upTo terminator: Character) -> String? {
        guard let end = characters[index...].firstIndex(of: terminator) else { return nil }
        defer { index = end + 1 }
        return String(characters[index..<end])
    }

    static func removingComments(_ value: String) -> String {
        var output = ""
        var depth = 0
        var inQuotes = false
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
                if depth == 0 { output.append(character) }
                continue
            }
            switch character {
            case "\\":
                escaped = true
                if depth == 0 { output.append(character) }
            case "\"" where depth == 0:
                inQuotes.toggle()
                output.append(character)
            case "(" where !inQuotes:
                depth += 1
            case ")" where !inQuotes && depth > 0:
                depth -= 1
                if depth == 0 { output.append(" ") }
            default:
                if depth == 0 { output.append(character) }
            }
        }
        return output
    }

    static func split(_ value: String, at separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == separator && !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    /// Whitespace-separated tokens, with whitespace around "=" and "." removed first ("dkim = pass").
    static func tokens(_ segment: String) -> [String] {
        let tight = segment.replacingOccurrences(of: #"\s*([=.])\s*"#, with: "$1", options: .regularExpression)
        return tight.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }
}
