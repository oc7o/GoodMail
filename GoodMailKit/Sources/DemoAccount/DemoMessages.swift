import Foundation
import JMAPKit

/// A header field as it appears in a message: its name, and its value after the colon with its line folding.
struct DemoHeader: Sendable, Equatable {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// The bytes behind the demo account's messages: attachments, whole messages (RFC 5322), and the header
/// fields JMAP returns in parsed forms (RFC 8621 §4.1.2).
enum DemoMessages {
    typealias Object = [String: JSONValue]

    // MARK: Attachments

    /// The demo account's own blobs, which are part of no upload.
    static func staticBlob(_ blobId: String) -> (data: Data, type: String)? {
        switch blobId {
        case "e3-file0": (flightConfirmation, "application/pdf")
        case "e5-file0": (invoice, "application/pdf")
        case "e5-logo": (Data(DemoData.logo.utf8), "image/svg+xml")
        default: nil
        }
    }

    /// The sizes match what the demo emails announce for the attachments.
    static let flightConfirmation = pdf(
        title: "Flight confirmation",
        lines: ["Lisbon, 3 November 2026", "Departure 08:05, arrival 11:40", "Booking reference DEMO42"],
        size: 184_320)
    static let invoice = pdf(
        title: "Northwind Hosting - Invoice 2041",
        lines: ["September 2026", "VPS S, 1 month: 12.00 EUR", "Charged to the card ending in 4411."],
        size: 61_440)

    /// A valid one-page PDF showing `title` and `lines`, padded with comment lines to `size` bytes if smaller.
    static func pdf(title: String, lines: [String], size: Int) -> Data {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        }
        var content = "BT /F1 22 Tf 72 760 Td (\(escaped(title))) Tj ET\n"
        for (index, line) in lines.enumerated() {
            content += "BT /F1 12 Tf 72 \(724 - 18 * index) Td (\(escaped(line))) Tj ET\n"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        // The second line's bytes above 127 mark the file as binary, as the PDF specification recommends.
        var body = Data("%PDF-1.4\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3]) + Data("\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.count)
            body += Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        func tail(xrefAt offset: Int) -> Data {
            var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
            for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
            xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(offset)\n%%EOF\n"
            return Data(xref.utf8)
        }
        // The tail's length depends on how many digits the xref offset has, which the padding changes.
        var padding = 0
        for _ in 0..<3 {
            padding = max(0, size - body.count - tail(xrefAt: body.count + padding).count)
        }
        var remaining = padding
        while remaining > 0 {
            let line = min(remaining, 80)
            body += Data((line == 1 ? "\n" : "%" + String(repeating: "-", count: line - 2) + "\n").utf8)
            remaining -= line
        }
        return body + tail(xrefAt: body.count)
    }

    // MARK: Messages

    /// The message an email is, as a server would hand it out for its `blobId`.
    static func message(_ email: Object, headers extra: [DemoHeader], blob: (String) -> Data?) -> Data {
        let body = mimeBody(email, blob: blob)
        let headers = extra + standardHeaders(email, encoded: true) + [DemoHeader("MIME-Version", "1.0")] + body.headers
        return Data((headers.map { "\($0.name): \($0.value)\r\n" }.joined() + "\r\n" + body.body).utf8)
    }

    /// The header fields JMAP derives from an email's properties.
    ///
    /// - Parameter encoded: Whether text other than ASCII is written as RFC 2047 encoded words, as in a message
    ///   file, rather than as it reads.
    static func standardHeaders(_ email: Object, encoded: Bool = false) -> [DemoHeader] {
        let word: (String) -> String = { encoded ? encodedWord($0) : $0 }
        var headers: [DemoHeader] = []
        for (property, name) in [("from", "From"), ("sender", "Sender"), ("to", "To"), ("cc", "Cc"),
                                 ("bcc", "Bcc"), ("replyTo", "Reply-To")] {
            let addresses = addressList(email[property], word: word)
            if !addresses.isEmpty { headers.append(DemoHeader(name, addresses)) }
        }
        if case .string(let subject)? = email["subject"] { headers.append(DemoHeader("Subject", word(subject))) }
        if let date = date(email["sentAt"]) ?? date(email["receivedAt"]) {
            headers.append(DemoHeader("Date", rfc5322Date(date)))
        }
        for (property, name) in [("messageId", "Message-ID"), ("inReplyTo", "In-Reply-To"),
                                 ("references", "References")] {
            let ids = strings(email[property])
            if !ids.isEmpty { headers.append(DemoHeader(name, ids.map { "<\($0)>" }.joined(separator: " "))) }
        }
        return headers
    }

    /// The body as MIME: the text and HTML versions, inline images, attachments; every part in base64.
    private static func mimeBody(_ email: Object, blob: (String) -> Data?) -> (headers: [DemoHeader], body: String) {
        let values = bodyValues(email)
        func leaf(_ part: Object) -> (headers: [DemoHeader], body: String) {
            let type = string(part["type"]).isEmpty ? "application/octet-stream" : string(part["type"])
            var headers: [DemoHeader]
            let data: Data
            if case .string(let partId)? = part["partId"], let value = values[partId] {
                headers = [DemoHeader("Content-Type", "\(type); charset=utf-8")]
                data = Data(value.utf8)
            } else {
                let name = string(part["name"])
                headers = [DemoHeader("Content-Type", name.isEmpty ? type : "\(type); name=\"\(name)\"")]
                data = blob(string(part["blobId"])) ?? Data()
                let disposition = string(part["disposition"]).isEmpty ? "attachment" : string(part["disposition"])
                headers.append(DemoHeader(
                    "Content-Disposition", name.isEmpty ? disposition : "\(disposition); filename=\"\(name)\""))
            }
            if case .string(let cid)? = part["cid"] { headers.append(DemoHeader("Content-ID", "<\(cid)>")) }
            headers.append(DemoHeader("Content-Transfer-Encoding", "base64"))
            return (headers, data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                                .endLineWithLineFeed]) + "\r\n")
        }
        func multipart(_ subtype: String, _ parts: [(headers: [DemoHeader], body: String)], level: Int)
            -> (headers: [DemoHeader], body: String) {
            let boundary = "=_demo_\(subtype)_\(level)"
            var body = ""
            for part in parts {
                body += "--\(boundary)\r\n" + part.headers.map { "\($0.name): \($0.value)\r\n" }.joined() + "\r\n"
                body += part.body
            }
            body += "--\(boundary)--\r\n"
            return ([DemoHeader("Content-Type", "multipart/\(subtype); boundary=\"\(boundary)\"")], body)
        }

        let text = objects(email["textBody"]).first
        let html = objects(email["htmlBody"]).first
        var main: (headers: [DemoHeader], body: String) = switch (text, html) {
        case let (text?, html?) where text != html: multipart("alternative", [leaf(text), leaf(html)], level: 2)
        case let (part?, _), let (nil, part?): leaf(part)
        case (nil, nil): ([DemoHeader("Content-Type", "text/plain; charset=utf-8")], "\r\n")
        }
        let attachments = objects(email["attachments"])
        let inline = attachments.filter { string($0["disposition"]) == "inline" && !string($0["cid"]).isEmpty }
        if !inline.isEmpty { main = multipart("related", [main] + inline.map(leaf), level: 1) }
        let files = attachments.filter { part in !inline.contains(part) }
        if !files.isEmpty { main = multipart("mixed", [main] + files.map(leaf), level: 0) }
        return main
    }

    private static func addressList(_ value: JSONValue?, word: (String) -> String) -> String {
        objects(value).map { address in
            let email = string(address["email"])
            let name = string(address["name"])
            return name.isEmpty ? email : "\(word(name)) <\(email)>"
        }.joined(separator: ", ")
    }

    /// `text` as an RFC 2047 encoded word if it isn't plain ASCII.
    private static func encodedWord(_ text: String) -> String {
        guard !text.allSatisfy(\.isASCII) else { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: Parsed header forms (RFC 8621 §4.1.2)

    /// The value of a `header:{name}[:as{Form}][:all]` property, or `nil` if `property` isn't one.
    static func headerProperty(_ property: String, of headers: [DemoHeader]) -> JSONValue? {
        var parts = property.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.removeFirst() == "header" else { return nil }
        let name = parts.removeFirst()
        let all = parts.last == "all"
        if all { parts.removeLast() }
        let form = parts.first ?? "asRaw"
        let values = headers.filter { $0.name.lowercased() == name.lowercased() }.map { parsed($0.value, as: form) }
        if all { return .array(values) }
        return values.last ?? .null
    }

    private static func parsed(_ raw: String, as form: String) -> JSONValue {
        let text = unfolded(raw)
        switch form {
        case "asRaw": return .string(" " + raw)
        case "asText": return .string(text)
        case "asAddresses": return .array(addresses(in: text))
        case "asMessageIds":
            let ids = text.matches(of: /<([^>]*)>/).map { String($0.output.1) }
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        case "asURLs":
            // RFC 2369: angle-bracketed URLs separated by commas; whitespace inside the brackets is ignored.
            let urls = text.matches(of: /<([^>]*)>/).map { $0.output.1.filter { !$0.isWhitespace } }
            return urls.isEmpty ? .null : .array(urls.map { .string(String($0)) })
        default: return .null
        }
    }

    /// RFC 8621 §4.1.2.2: line breaks removed, whitespace at both ends trimmed.
    private static func unfolded(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A best-effort address-list parser for the demo's own header fields: `Name <a@b>, c@d`.
    private static func addresses(in text: String) -> [JSONValue] {
        text.split(separator: ",").compactMap { item -> JSONValue? in
            let item = item.trimmingCharacters(in: .whitespaces)
            if let match = item.firstMatch(of: /^(.*?)\s*<([^>]+)>$/) {
                let name = String(match.output.1).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                return ["name": name.isEmpty ? .null : .string(name), "email": .string(String(match.output.2))]
            }
            return item.contains("@") ? ["name": .null, "email": .string(item)] : nil
        }
    }

    // MARK: Body structure (RFC 8621 §4.1.4)

    /// A body part for working out the body lists: the stored part of a leaf, the parts of a multipart.
    struct Part {
        var leaf: Object
        var type: String
        var disposition: String? = nil
        var name: String? = nil
        var subParts: [Part]? = nil
    }

    /// `textBody`, `htmlBody` and `attachments` of a body structure, by the algorithm in RFC 8621 §4.1.4.
    static func bodyLists(of structure: Part) -> (text: [Object], html: [Object], attachments: [Object]) {
        var text: [Object] = []
        var html: [Object] = []
        var attachments: [Object] = []
        parse([structure], multipartType: "mixed", inAlternative: false, textActive: true, htmlActive: true,
              text: &text, html: &html, attachments: &attachments)
        return (text, html, attachments)
    }

    private static func parse(
        _ parts: [Part], multipartType: String, inAlternative: Bool, textActive: Bool, htmlActive: Bool,
        text: inout [Object], html: inout [Object], attachments: inout [Object]
    ) {
        var textActive = textActive
        var htmlActive = htmlActive
        let textLength = textActive ? text.count : -1
        let htmlLength = htmlActive ? html.count : -1
        func isInlineMedia(_ type: String) -> Bool {
            type.hasPrefix("image/") || type.hasPrefix("audio/") || type.hasPrefix("video/")
        }
        for (index, part) in parts.enumerated() {
            let isInline = part.disposition != "attachment"
                && (part.type == "text/plain" || part.type == "text/html" || isInlineMedia(part.type))
                && (index == 0 || (multipartType != "related" && (isInlineMedia(part.type) || part.name == nil)))
            if part.type.hasPrefix("multipart/") {
                let subtype = String(part.type.dropFirst("multipart/".count))
                parse(
                    part.subParts ?? [], multipartType: subtype, inAlternative: inAlternative || subtype == "alternative",
                    textActive: textActive, htmlActive: htmlActive, text: &text, html: &html, attachments: &attachments)
            } else if isInline {
                if multipartType == "alternative" {
                    switch part.type {
                    case "text/plain": if textActive { text.append(part.leaf) }
                    case "text/html": if htmlActive { html.append(part.leaf) }
                    default: attachments.append(part.leaf)
                    }
                    continue
                } else if inAlternative {
                    if part.type == "text/plain" { htmlActive = false }
                    if part.type == "text/html" { textActive = false }
                }
                if textActive { text.append(part.leaf) }
                if htmlActive { html.append(part.leaf) }
                if (!textActive || !htmlActive) && isInlineMedia(part.type) { attachments.append(part.leaf) }
            } else {
                attachments.append(part.leaf)
            }
        }
        if multipartType == "alternative", textActive, htmlActive {
            if textLength == text.count, htmlLength != html.count { text += html[htmlLength...] }
            if htmlLength == html.count, textLength != text.count { html += text[textLength...] }
        }
    }

    // MARK: JSON helpers

    static func string(_ value: JSONValue?) -> String {
        if case .string(let string)? = value { string } else { "" }
    }

    static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .string(let string) = $0 { string } else { nil } }
    }

    static func objects(_ value: JSONValue?) -> [Object] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let string)? = value else { return nil }
        return try? Date(string, strategy: .iso8601)
    }

    /// The text of each body value by part id.
    static func bodyValues(_ email: Object) -> [String: String] {
        guard case .object(let values)? = email["bodyValues"] else { return [:] }
        return values.compactMapValues { value in
            if case .object(let value) = value, case .string(let text)? = value["value"] { text } else { nil }
        }
    }
}
