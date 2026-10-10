import Darwin
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

    /// A header field as the message has it: its name and its raw value, folding included, the form of JMAP's
    /// `headers` property (RFC 8621 §4.1.3).
    public struct HeaderField: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        func `is`(_ name: String) -> Bool {
            self.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The provider that received the message. Its MX hosts, and the authserv-ids of the verdicts it writes into
    /// Authentication-Results fields, are hosts of `domain`; its internal hosts are under `.internal`.
    public struct Receiver: Sendable, Hashable {
        public let domain: String

        public init(domain: String) {
            self.domain = domain.lowercased()
        }

        /// Fastmail, whose MX hosts are named like `phl-mx-03.messagingengine.com`.
        public static let fastmail = Receiver(domain: "messagingengine.com")

        func isHost(_ host: String) -> Bool {
            host.hasSuffix("." + domain)
        }

        /// One of the receiver's hosts, an internal host, or a private address.
        func ownsHost(_ word: String) -> Bool {
            if word.hasPrefix("["), word.hasSuffix("]") {
                var literal = word.dropFirst().dropLast()
                if literal.lowercased().hasPrefix("ipv6:") { literal = literal.dropFirst(5) }
                let address = String(literal)
                return Receiver.isNumericAddress(address) && !UnsubscribeTarget.isPublic(address: address)
            }
            let host = ReceivedField.normalizedHost(word)
            return host == "localhost" || host.hasSuffix(".internal") || isHost(host)
        }

        private static func isNumericAddress(_ text: String) -> Bool {
            var v4 = in_addr()
            var v6 = in6_addr()
            return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
        }
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
    /// - in `headers`, every header field of the message topmost first, the receiver's own verdicts can be told
    ///   apart from the Authentication-Results that came with the message (`receiverVerdicts(in:receiver:)`);
    /// - one of those verdicts' `dkim=pass` results pairs, by `header.d` and a `header.b` prefix of at least 8
    ///   characters, with exactly one DKIM-Signature, and that signature's `h=` covers both List-Unsubscribe and
    ///   List-Unsubscribe-Post.
    public static func methods(
        listUnsubscribe: [[String]], listUnsubscribePost: [String], headers: [HeaderField],
        receiver: Receiver = .fastmail
    ) -> [Method] {
        var methods: [Method] = []
        if let target = oneClickTarget(
            listUnsubscribe: listUnsubscribe, listUnsubscribePost: listUnsubscribePost, headers: headers,
            receiver: receiver)
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
        listUnsubscribe: [[String]], listUnsubscribePost: [String], headers: [HeaderField], receiver: Receiver
    ) -> URL? {
        guard listUnsubscribe.count == 1 else { return nil }
        let https = urls(in: listUnsubscribe[0]).filter { $0.scheme?.lowercased() == "https" }
        guard https.count == 1, let target = https.first, UnsubscribeTarget.isAllowed(target),
              listUnsubscribePost.count == 1,
              listUnsubscribePost[0].trimmingCharacters(in: .whitespacesAndNewlines) == oneClickBody,
              let verdicts = receiverVerdicts(in: headers, receiver: receiver)
        else { return nil }
        let signatures = headers.filter { $0.is("DKIM-Signature") }.compactMap { DKIMSignature($0.value) }
        let paired = verdicts.flatMap(\.dkimPasses).contains { pass in
            guard pass.signaturePrefix.count >= 8 else { return false }
            // header.b exists to tell signatures apart (RFC 6008); one that names two doesn't.
            let named = signatures.filter {
                $0.domain == pass.domain && $0.signature.hasPrefix(pass.signaturePrefix)
            }
            guard named.count == 1, let signature = named.first else { return false }
            return signature.signedHeaders.isSuperset(of: ["list-unsubscribe", "list-unsubscribe-post"])
        }
        return paired ? target : nil
    }

    /// The Authentication-Results fields the receiver wrote itself, topmost first, or `nil` if they can't be told
    /// apart from those that came with the message.
    ///
    /// They are every Authentication-Results field above the Received field with which the receiver's MX
    /// accepted the message from outside: the first Received field whose `by` host is the receiver's and whose
    /// `from` part names more than the receiver's own systems (`ReceivedField.isFrom(within:)`). Everything below
    /// it came with the message and may be forged, even where it names one of the receiver's hosts. The answer is
    /// `nil` without such a Received field, when a Received field above it can't be read, and when any of the
    /// fields above it doesn't come from one of the receiver's hosts or can't be read.
    static func receiverVerdicts(in headers: [HeaderField], receiver: Receiver) -> [AuthenticationResults]? {
        var verdicts: [AuthenticationResults] = []
        for field in headers {
            if field.is("Authentication-Results") {
                guard let results = AuthenticationResults(field.value), receiver.isHost(results.authServID) else {
                    return nil
                }
                verdicts.append(results)
            } else if field.is("Received") {
                let hop = ReceivedField(field.value)
                guard hop.isReadable else { return nil }
                if let by = hop.byHost, receiver.isHost(by), hop.from != nil, !hop.isFrom(within: receiver) {
                    return verdicts
                }
            }
        }
        return nil
    }
}

/// A Received field (RFC 5321 §4.4), as far as telling the receiver's own hops from the one that brought the
/// message in.
///
/// Postfix writes `from <HELO name> (<reverse DNS name or "unknown"> [<address>]) … by <host> …`. The HELO name
/// is whatever the sending host claimed; the comment after it records what the receiving host found out itself.
/// So a hop counts as internal only when both name the receiver's own systems.
struct ReceivedField {
    /// A word outside comments, and the comments that follow it.
    struct Word {
        var text: String
        var comments: [String] = []
    }

    /// The words up to the date, which follows the ";".
    private(set) var words: [Word] = []
    /// False when comments or quotes don't balance, or the field doesn't start with a `from` or `by` clause in
    /// that order, so that its clauses can't be told apart.
    private(set) var isReadable = true

    init(_ value: String) {
        var current = ""
        var comment = ""
        var depth = 0
        var inQuotes = false
        var escaped = false
        func endWord() {
            if !current.isEmpty { words.append(Word(text: current)) }
            current = ""
        }
        scanning: for character in value {
            if escaped {
                escaped = false
                if depth > 0 { comment.append(character) } else { current.append(character) }
            } else if character == "\\" {
                escaped = true
            } else if depth > 0 {
                switch character {
                case "(":
                    depth += 1
                    comment.append(character)
                case ")":
                    depth -= 1
                    if depth > 0 {
                        comment.append(character)
                    } else {
                        if !words.isEmpty { words[words.count - 1].comments.append(comment) }
                        comment = ""
                    }
                default:
                    comment.append(character)
                }
            } else if inQuotes {
                if character == "\"" { inQuotes = false } else { current.append(character) }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case "(":
                    endWord()
                    depth = 1
                case ")":
                    isReadable = false
                    break scanning
                case ";":
                    break scanning
                default:
                    if character.isWhitespace { endWord() } else { current.append(character) }
                }
            }
        }
        if depth > 0 || inQuotes || escaped { isReadable = false }
        endWord()
        if isReadable { isReadable = hasStandardShape }
    }

    /// `from <domain> by <domain> …` or `by <domain> …`: RFC 5321 gives each of those clauses exactly one domain.
    /// A HELO name made to look like more words, or like another clause, breaks that shape.
    private var hasStandardShape: Bool {
        guard let first = words.first?.text.lowercased() else { return false }
        switch first {
        case "from": return words.count >= 4 && words[2].text.lowercased() == "by"
        case "by": return words.count >= 2
        default: return false
        }
    }

    /// The name the sending host gave, with the comments after it.
    var from: Word? {
        isReadable && words[0].text.lowercased() == "from" ? words[1] : nil
    }

    /// The host that wrote this field, lower-cased, without a trailing dot.
    var byHost: String? {
        guard isReadable else { return nil }
        return Self.normalizedHost(words[from == nil ? 1 : 3].text)
    }

    /// Whether the hop came from the receiver's own systems: the name the sender gave is the receiver's own, and
    /// so is every name and address in the comments that record the connection, the ones holding an address
    /// literal. Other comments, such as the TLS details, don't count. "unknown", for a sender without a reverse
    /// DNS name, is nobody's own. A field without a `from` clause records no connection, so it counts as within.
    func isFrom(within receiver: ListUnsubscribe.Receiver) -> Bool {
        guard let from else { return true }
        guard receiver.ownsHost(from.text) else { return false }
        for comment in from.comments {
            let tokens = comment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.contains(where: { $0.hasPrefix("[") }) else { continue }
            for token in tokens {
                let pair = token.split(separator: "=", maxSplits: 1)
                let isHELO = pair.count == 2 && ["helo", "ehlo"].contains(pair[0].lowercased())
                guard receiver.ownsHost(isHELO ? String(pair[1]) : token) else { return false }
            }
        }
        return true
    }

    static func normalizedHost(_ word: String) -> String {
        var host = word.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
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
