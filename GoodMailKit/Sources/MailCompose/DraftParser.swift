import Foundation
import JMAPKit
import MailPrivacy

/// A draft read back from the server, and how faithfully the editor can hold it.
public struct ParsedDraft: Sendable, Equatable {
    public enum Fidelity: Sendable, Equatable {
        /// Editing and saving it again changes nothing the user didn't change.
        case exact
        /// The editor can only hold a simplified version; show the original read-only until the user decides.
        case simplified(Set<MailBodyHTMLReader.Feature>)
    }

    public var draft: MessageDraft
    public var fidelity: Fidelity

    public init(draft: MessageDraft, fidelity: Fidelity) {
        self.draft = draft
        self.fidelity = fidelity
    }
}

/// Opens a draft saved on the server, by GoodMail on any device or by another client.
///
/// The HTML is split the way `MessageAssembler` builds it: a trailing `<blockquote type="cite">` with the line
/// before it ("On … wrote:", "Begin forwarded message:") becomes the preserved tail, kept as it is; a top-level
/// `<div class="signature">` is dropped and marks the draft as having a signature; the rest is read into editor
/// text. Each section's separating empty line is removed with it, so GoodMail's own drafts come back exactly.
public enum DraftParser {
    public static func parse(_ email: Email, fallbackDomain: String) -> ParsedDraft {
        let htmlParts = (email.htmlBody ?? []).filter { $0.type?.lowercased() == "text/html" }
        let textParts = ((email.textBody ?? []) + (email.htmlBody ?? []))
            .filter { $0.type?.lowercased() == "text/plain" }
        let plainAlternative = uniqueParts(textParts).compactMap { QuotedMessage.value(of: $0, in: email) }
            .joined(separator: "\n")

        var body = AttributedString()
        var dropped: Set<MailBodyHTMLReader.Feature> = []
        var tail: PreservedTail?
        var hasSignature = false
        let usedParts: [EmailBodyPart]
        if !htmlParts.isEmpty {
            let html = htmlParts.compactMap { QuotedMessage.value(of: $0, in: email) }.joined()
            let sections = Sections(html: html, plainAlternative: plainAlternative, email: email)
            body = sections.body.text
            dropped = sections.body.dropped
            tail = sections.tail
            hasSignature = sections.hasSignature
            usedParts = htmlParts
        } else {
            body = MailBodyNormalizer.normalize(AttributedString(plainAlternative))
            usedParts = uniqueParts(textParts)
        }
        if usedParts.contains(where: { $0.partId.flatMap { email.bodyValues?[$0]?.isTruncated } == true }) {
            dropped.insert(.other)
        }

        let from = email.from?.first
        let messageID = email.messageId?.first ?? MessageDraft.newMessageID(
            domain: from.flatMap { AddressParser.domain(of: $0.email) } ?? fallbackDomain)
        let draft = MessageDraft(
            kind: kind(of: email, tail: tail), from: from, messageID: messageID, to: email.to ?? [],
            cc: email.cc ?? [], bcc: email.bcc ?? [], replyTo: email.replyTo ?? [], subject: email.subject ?? "",
            body: body, attachments: attachments(of: email), inReplyTo: email.inReplyTo,
            references: email.references, preservedTail: tail, includesSignature: hasSignature)
        return ParsedDraft(draft: draft, fidelity: dropped.isEmpty ? .exact : .simplified(dropped))
    }

    static func kind(of email: Email, tail: PreservedTail?) -> MessageDraft.Kind {
        if tail?.text.hasPrefix("Begin forwarded message") == true { return .forward }
        if email.inReplyTo?.isEmpty == false { return .reply }
        if ReplyBuilder.forwardSubject(email.subject) == (email.subject ?? "").trimmingCharacters(in: .whitespaces),
           email.subject?.isEmpty == false {
            return .forward
        }
        return .new
    }

    static func attachments(of email: Email) -> [DraftAttachment] {
        (email.attachments ?? []).compactMap { part in
            guard let blobId = part.blobId, !(part.disposition == "inline" && part.cid != nil) else { return nil }
            let type = part.type ?? "application/octet-stream"
            return DraftAttachment(
                name: SafeFilename.make(part.name, mimeType: type), type: type, size: part.size ?? 0,
                source: .server(blobId: blobId))
        }
    }

    static func uniqueParts(_ parts: [EmailBodyPart]) -> [EmailBodyPart] {
        var seen = Set<String>()
        return parts.filter { $0.partId.map { seen.insert($0).inserted } ?? false }
    }

    /// The draft's HTML split into the user's text, signature and tail.
    struct Sections {
        var body: MailBodyHTMLReader.Result
        var tail: PreservedTail?
        var hasSignature = false

        init(html: String, plainAlternative: String, email: Email) {
            let options = OutgoingHTMLSanitizer.Options(cleansLinks: false, allowedClasses: ["signature"])
            let clean = OutgoingHTMLSanitizer.sanitize(html, options: options).html
            var nodes = HTMLNode.parse(clean)

            if let (attribution, quote) = Self.removeTail(from: &nodes) {
                let start = (attribution ?? quote).range.lowerBound
                let sanitized = OutgoingHTMLSanitizer.sanitize(String(clean[start..<quote.range.upperBound]))
                tail = PreservedTail(
                    html: sanitized.html,
                    text: Self.tailText(
                        attribution: attribution.map { Self.collapsed($0.plainText) }, quote: quote,
                        plainAlternative: plainAlternative),
                    inlineParts: Self.inlineParts(sanitized.contentIDs, of: email))
            }

            if let last = Self.lastIndex(in: nodes, skippingEmptyBlocks: false),
               nodes[last].name == "div",
               nodes[last].attributes["class"]?.split(separator: " ").contains("signature") == true
            {
                nodes.removeSubrange(last...)
                Self.removeSeparator(from: &nodes)
                hasSignature = true
            }
            body = MailBodyHTMLReader.read(nodes: nodes)
        }

        /// Takes a trailing `<blockquote type="cite">` and the attribution line before it out of `nodes`, with the
        /// empty line that separates them from the text. Apple Mail's layouts are recognised too: on the Mac the
        /// quote, attribution inside, ends a trailing `<div>`; on iOS the attribution is quoted on its own at the
        /// end of the `<div>` before the quote.
        static func removeTail(from nodes: inout [HTMLNode]) -> (attribution: HTMLNode?, quote: HTMLNode)? {
            guard let last = lastIndex(in: nodes, skippingEmptyBlocks: true) else { return nil }
            let node = nodes[last]
            if node.name == "blockquote", node.attributes["type"]?.lowercased() == "cite" {
                var start = last
                var attribution: HTMLNode?
                if let previous = lastIndex(in: nodes, before: last) {
                    if isAttribution(nodes[previous]) {
                        start = previous
                        attribution = nodes[previous]
                    } else if case .element("div", let attributes, var children) = nodes[previous].content,
                              let inner = lastIndex(in: children, skippingEmptyBlocks: false),
                              children[inner].name == "blockquote", isAttribution(children[inner]) {
                        attribution = children[inner]
                        children.removeSubrange(inner...)
                        removeSeparator(from: &children)
                        nodes[previous] = HTMLNode(
                            content: .element(name: "div", attributes: attributes, children: children),
                            range: nodes[previous].range)
                    }
                }
                nodes.removeSubrange(start...)
                removeSeparator(from: &nodes)
                return (attribution, node)
            }
            guard case .element("div", let attributes, var children) = node.content,
                  let found = removeTail(from: &children)
            else { return nil }
            nodes[last] = HTMLNode(
                content: .element(name: "div", attributes: attributes, children: children), range: node.range)
            nodes.removeSubrange((last + 1)...)
            return found
        }

        /// The last node that isn't whitespace (and, if asked, isn't an empty block such as `<div><br></div>`).
        static func lastIndex(in nodes: [HTMLNode], skippingEmptyBlocks: Bool) -> Int? {
            nodes.indices.last { !nodes[$0].isWhitespace && !(skippingEmptyBlocks && isEmptyBlock(nodes[$0])) }
        }

        static func lastIndex(in nodes: [HTMLNode], before index: Int) -> Int? {
            nodes[..<index].indices.last { !nodes[$0].isWhitespace }
        }

        /// `<div><br></div>`, `<br>` or an empty `<div>`/`<p>`: an empty line, nothing else.
        static func isEmptyBlock(_ node: HTMLNode) -> Bool {
            switch node.name {
            case "br": true
            case "div", "p": node.children.allSatisfy { $0.isWhitespace || $0.name == "br" }
                && node.children.filter { $0.name == "br" }.count <= 1
            default: false
            }
        }

        /// Removes the one empty line that separates a section from the text above it.
        static func removeSeparator(from nodes: inout [HTMLNode]) {
            guard let last = lastIndex(in: nodes, skippingEmptyBlocks: false), isEmptyBlock(nodes[last]) else { return }
            nodes.removeSubrange(last...)
        }

        /// A short line of text ending in a colon, such as "On 9 Oct 2026 at 14:03 UTC, Maya wrote:".
        static func isAttribution(_ node: HTMLNode) -> Bool {
            guard ["div", "p", "blockquote"].contains(node.name),
                  node.children.allSatisfy({ child in
                      child.name.map { !["div", "p", "blockquote", "ul", "ol", "table"].contains($0) } ?? true
                  })
            else { return false }
            let text = collapsed(node.plainText)
            return text.hasSuffix(":") && text.count <= 500 && text.contains(where: \.isLetter)
        }

        static func collapsed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// The tail's text alternative: the draft's own plain text from the attribution on, when it has one;
        /// otherwise the attribution and the quote rendered from the HTML.
        static func tailText(attribution: String?, quote: HTMLNode, plainAlternative: String) -> String {
            if let attribution, let range = plainAlternative.range(of: attribution, options: .backwards) {
                return String(plainAlternative[range.lowerBound...])
            }
            let quoted = HTMLNode.text(of: quote)
            guard let attribution else { return MessageAssembler.quoteLines(quoted) }
            if attribution.hasPrefix("Begin forwarded message") { return attribution + "\n\n" + quoted }
            return attribution + "\n" + MessageAssembler.quoteLines(quoted)
        }

        static func inlineParts(_ contentIDs: [String], of email: Email) -> [OriginalMessage.InlinePart] {
            contentIDs.compactMap { cid in
                guard let part = email.inlineImagePart(cid: cid), let blobId = part.blobId else { return nil }
                return OriginalMessage.InlinePart(
                    cid: cid, blobId: blobId, type: part.type ?? "application/octet-stream", name: part.name)
            }
        }
    }
}

extension HTMLNode {
    /// The plain-text rendering the sanitizer gives this node's content.
    static func text(of node: HTMLNode) -> String {
        let markup = node.children.map(\.markup).joined()
        return OutgoingHTMLSanitizer.sanitize(markup).text
    }

    /// The node written back as strict HTML.
    var markup: String {
        switch content {
        case .text(let text):
            return HTMLEscaping.text(text)
        case .element(let name, let attributes, let children):
            let attributeList = attributes.keys.sorted().map { key in
                " \(key)=\"\(HTMLEscaping.attribute(attributes[key] ?? ""))\""
            }
            let open = "<\(name)\(attributeList.joined())>"
            if OutgoingHTMLSanitizer.voidElements.contains(name) { return open }
            return open + children.map(\.markup).joined() + "</\(name)>"
        }
    }
}
