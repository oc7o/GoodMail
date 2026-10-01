import Foundation
import JMAPKit

/// What goes into the full-text index for an email.
enum SearchText {
    static func people(of email: Email) -> String {
        [email.from, email.to, email.cc, email.bcc]
            .flatMap { $0 ?? [] }
            .flatMap { [$0.name, $0.email] }
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The readable text of the body if it was fetched, else the server's preview.
    static func body(of email: Email) -> String {
        let parts = (email.htmlBody ?? []).compactMap { part -> String? in
            guard let id = part.partId, let value = email.bodyValues?[id]?.value else { return nil }
            return part.type == "text/html" ? plainText(fromHTML: value) : value
        }
        return parts.isEmpty ? (email.preview ?? "") : parts.joined(separator: "\n")
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            (#"<(style|script|head)\b.*?</\1\s*>"#, " "), (#"<[^>]+>"#, " "),
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            (#"\s+"#, " "),
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
