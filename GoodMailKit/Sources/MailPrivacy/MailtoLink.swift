import Foundation

/// A `mailto:` URL (RFC 6068) reduced to what is safe to act on: recipients, subject and body.
///
/// Every other header a link can carry (cc, bcc, in-reply-to, arbitrary ones) is ignored, so a link can never
/// add hidden recipients or thread a message into a conversation the user didn't pick.
public struct MailtoLink: Sendable, Hashable {
    public var to: [String]
    public var subject: String?
    public var body: String?

    public init(to: [String], subject: String? = nil, body: String? = nil) {
        self.to = to
        self.subject = subject
        self.body = body
    }

    public init?(_ url: URL) {
        let string = url.absoluteString
        guard let colon = string.firstIndex(of: ":"), string[..<colon].lowercased() == "mailto" else { return nil }
        let rest = string[string.index(after: colon)...]
        let question = rest.firstIndex(of: "?")
        let path = rest[..<(question ?? rest.endIndex)]

        var to = Self.addresses(Self.decode(path))
        var subject: String?
        var body: String?
        if let question {
            for field in rest[rest.index(after: question)...].split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = Self.decode(pair[0]).lowercased()
                let value = pair.count == 2 ? Self.decode(pair[1]) : ""
                switch name {
                case "to": to += Self.addresses(value)
                // RFC 6068 §5: the first occurrence counts.
                case "subject": subject = subject ?? value
                case "body": body = body ?? value.replacingOccurrences(of: "\r\n", with: "\n")
                default: break
                }
            }
        }
        self.init(to: to, subject: subject, body: body)
    }

    /// Percent-decoding only: in mailto URLs "+" is a plus sign, not a space (RFC 6068 §5).
    static func decode(_ text: Substring) -> String {
        decode(String(text))
    }

    static func decode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    static func addresses(_ list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
