import Foundation
import JMAPKit
import MailPrivacy

/// A complete body for `Email/set`: both alternatives, plus the inline parts the HTML refers to.
public struct OutgoingBody: Sendable, Equatable {
    public var html: String
    public var text: String
    /// `cid:` values the quote, signature or preserved tail refer to; their parts are attached by blob id.
    public var contentIDs: [String]
    public var removedTrackers: Int

    public init(html: String, text: String, contentIDs: [String], removedTrackers: Int) {
        self.html = html
        self.text = text
        self.contentIDs = contentIDs
        self.removedTrackers = removedTrackers
    }
}

public struct AssemblyOptions: Sendable {
    /// The From identity's signature; nil on masked sends.
    public var signature: Signature?
    /// Addresses written into the message by GoodMail itself that must stay out of it: on masked sends, the
    /// user's own addresses other than From. They are left out of a forward's header block, and a reply's
    /// attribution then says "I wrote" instead of naming them.
    public var hidesAddress: @Sendable (String) -> Bool

    public init(signature: Signature? = nil, hidesAddress: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.signature = signature
        self.hidesAddress = hidesAddress
    }
}

/// Builds the body of a message or draft around the user's text.
///
/// The composer edits only the user's own words; the original is shown read-only under the editor and joins the
/// message here, sanitised. One neutral structure serves drafts and sent messages alike, with nothing that names
/// GoodMail:
///
///     <div>your text</div>…
///     <div><br></div><div class="signature">signature</div>
///     <div><br></div><div>On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist &lt;maya@…&gt; wrote:</div>
///     <blockquote type="cite">original</blockquote>
///
/// A forward has `<div>Begin forwarded message:</div>` and the original's header lines in the blockquote
/// instead; a draft from another client has its preserved tail. Dates are UTC in a fixed English format, so the
/// message doesn't reveal where the user is. The text alternative puts "-- " before the signature unless it
/// starts with one already (RFC 3676 §4.3), and quotes with "> ".
public enum MessageAssembler {
    public static func assemble(_ draft: MessageDraft, options: AssemblyOptions) -> OutgoingBody {
        var html: [String] = []
        var text: [String] = []
        var contentIDs: [String] = []
        var trackers = 0
        func add(_ sanitized: OutgoingHTMLSanitizer.Result?) {
            guard let sanitized else { return }
            for id in sanitized.contentIDs where !contentIDs.contains(id) { contentIDs.append(id) }
            trackers += sanitized.removedTrackers
        }

        if !draft.body.characters.isEmpty {
            let own = MailHTMLWriter.write(draft.body)
            html.append(own.html)
            text.append(own.text)
        }

        if draft.includesSignature, let signature = options.signature, !signature.isEmpty {
            let sanitized = nonBlank(signature.html).map { OutgoingHTMLSanitizer.sanitize($0) }
            let signatureText = nonBlank(signature.text).map(unifiedLineBreaks) ?? sanitized?.text ?? ""
            html.append("<div class=\"signature\">\(sanitized?.html ?? Self.html(fromPlainText: signatureText))</div>")
            text.append(startsWithDelimiter(signatureText) ? signatureText : "-- \n" + signatureText)
            add(sanitized)
        }

        if let tail = draft.preservedTail {
            let sanitized = OutgoingHTMLSanitizer.sanitize(tail.html)
            html.append(sanitized.html)
            text.append(tail.text)
            add(sanitized)
        } else if let original = draft.original, let quoted = quotedBody(original.quote) {
            switch draft.kind {
            case .reply, .replyAll:
                let hidden = options.hidesAddress(original.quote.fromEmail)
                let line = attribution(for: original.quote, hidingSender: hidden)
                html.append(
                    "<div>\(HTMLEscaping.text(line))</div><blockquote type=\"cite\">\(quoted.html)</blockquote>")
                text.append(line + "\n" + quoteLines(quoted.text))
                add(quoted.sanitized)
            case .forward:
                let header = forwardHeader(original.quote, hiding: options.hidesAddress)
                html.append("<div>Begin forwarded message:</div><blockquote type=\"cite\">"
                    + header.map { "<div><b>\($0.name):</b> \(HTMLEscaping.text($0.value))</div>" }.joined()
                    + separator + quoted.html + "</blockquote>")
                let headerText = header.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                text.append("Begin forwarded message:\n\n" + headerText + "\n\n" + quoted.text)
                add(quoted.sanitized)
            case .new, .forwardAsAttachment:
                break
            }
        }

        let document = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>"
            + html.joined(separator: separator) + "</body></html>"
        return OutgoingBody(
            html: document, text: text.joined(separator: "\n\n"), contentIDs: contentIDs, removedTrackers: trackers)
    }

    /// "On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist <maya@lindqvist.example> wrote:"
    public static func attribution(for quote: QuotedMessage) -> String {
        attribution(for: quote, hidingSender: false)
    }

    static func attribution(for quote: QuotedMessage, hidingSender: Bool) -> String {
        let sender = hidingSender ? "I" : address(name: quote.fromName, email: quote.fromEmail)
        return "On \(formatted(quote.date)), \(sender) wrote:"
    }

    /// "9 Oct 2026 at 14:03 UTC", whatever the device's time zone, locale and calendar.
    static func formatted(_ date: Date) -> String {
        let style = Date.VerbatimFormatStyle(
            format: """
                \(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits) at \
                \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits) UTC
                """,
            locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt, calendar: Calendar(identifier: .gregorian))
        return date.formatted(style)
    }

    // MARK: Parts

    static let separator = "<div><br></div>"

    struct QuotedBody {
        var html: String
        var text: String
        var sanitized: OutgoingHTMLSanitizer.Result?
    }

    /// The original, sanitised: trackers removed, link tracking parameters stripped, other remote images kept for
    /// the recipient's client to decide about.
    static func quotedBody(_ quote: QuotedMessage) -> QuotedBody? {
        if let html = quote.html {
            let sanitized = OutgoingHTMLSanitizer.sanitize(html)
            let text = quote.text.map(unifiedLineBreaks) ?? sanitized.text
            return QuotedBody(html: sanitized.html, text: text, sanitized: sanitized)
        }
        guard let text = quote.text.map(unifiedLineBreaks) else { return nil }
        return QuotedBody(html: html(fromPlainText: text), text: text, sanitized: nil)
    }

    static func forwardHeader(_ quote: QuotedMessage, hiding: (String) -> Bool) -> [(name: String, value: String)] {
        var lines: [(name: String, value: String)] = []
        if !quote.fromEmail.isEmpty, !hiding(quote.fromEmail) {
            lines.append(("From", address(name: quote.fromName, email: quote.fromEmail)))
        }
        lines.append(("Subject", quote.subject))
        lines.append(("Date", formatted(quote.date)))
        for (name, addresses) in [("To", quote.to), ("Cc", quote.cc)] {
            let shown = addresses.filter { !hiding($0.email) }.map { address(name: $0.name, email: $0.email) }
            if !shown.isEmpty { lines.append((name, shown.joined(separator: ", "))) }
        }
        return lines
    }

    static func address(name: String?, email: String) -> String {
        guard let name, !name.isEmpty, name != email else { return email }
        return "\(name) <\(email)>"
    }

    /// RFC 3676-style quoting: "> " before each line, ">" before lines that are already quoted or empty.
    static func quoteLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(">") ? ">" + $0 : ($0.isEmpty ? ">" : "> " + $0) }
            .joined(separator: "\n")
    }

    static func startsWithDelimiter(_ signature: String) -> Bool {
        let firstLine = signature.prefix { $0 != "\n" }
        return firstLine.trimmingCharacters(in: .whitespaces) == "--"
    }

    static func nonBlank(_ text: String?) -> String? {
        text.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    }

    static func unifiedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Plain text as HTML: one `<div>` per line, spaces kept the way the HTML writer keeps them.
    static func html(fromPlainText text: String) -> String {
        unifiedLineBreaks(text).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var afterSpace = true
            var content = MailHTMLWriter.escapeText(String(line), afterSpace: &afterSpace)
            if afterSpace, content.hasSuffix(" ") { content = String(content.dropLast()) + "&nbsp;" }
            return "<div>\(content.isEmpty ? "<br>" : content)</div>"
        }.joined()
    }
}
