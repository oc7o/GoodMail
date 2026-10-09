import Foundation
import JMAPKit
import MailPrivacy

/// Drafts for replies and forwards: recipients, subject, threading headers and what to quote or attach.
public enum ReplyBuilder {
    /// - To: the original's Reply-To, else its From. When the original came from one of the user's own
    ///   addresses (a follow-up to a message they sent), its To instead, and reply-all adds its Cc.
    /// - Reply-all Cc: the original's To and Cc without the user's own addresses (`isOwn`, which also knows
    ///   wildcard identities and masked addresses) and without anyone already in To.
    /// - Threading: In-Reply-To is the parent's Message-ID; References continue the parent's chain
    ///   (RFC 5322 §3.6.4).
    public static func reply(to original: Email, all: Bool, from sender: EmailAddress?, isOwn: (String) -> Bool)
        -> MessageDraft
    {
        let originalFrom = original.from ?? []
        let isFollowUp = !originalFrom.isEmpty && originalFrom.allSatisfy { isOwn($0.email) }
        var to: [EmailAddress]
        if isFollowUp {
            let recipients = original.to ?? []
            let others = recipients.filter { !isOwn($0.email) }
            to = others.isEmpty ? recipients : others
        } else if let replyTo = original.replyTo, !replyTo.isEmpty {
            to = replyTo
        } else {
            to = originalFrom
        }
        to = unique(to)

        var cc: [EmailAddress] = []
        if all {
            let candidates = isFollowUp ? (original.cc ?? []) : (original.to ?? []) + (original.cc ?? [])
            let excluded = Set(to.map { $0.email.lowercased() } + [sender?.email.lowercased()].compactMap { $0 })
            cc = unique(candidates.filter { !isOwn($0.email) && !excluded.contains($0.email.lowercased()) })
        }

        let messageID = original.messageId.flatMap { $0.isEmpty ? nil : $0 }
        var references = original.references ?? (original.inReplyTo?.count == 1 ? original.inReplyTo : nil) ?? []
        references += messageID ?? []

        return MessageDraft(
            kind: all ? .replyAll : .reply, from: sender, to: to, cc: cc, subject: replySubject(original.subject),
            inReplyTo: messageID, references: references.isEmpty ? nil : references,
            original: OriginalMessage(original))
    }

    /// Inline, the original's files come along by blob id, nothing downloaded. As an attachment, the whole
    /// original goes as one `message/rfc822` part named after its subject. Forwards start new threads, so they
    /// carry no References or In-Reply-To.
    public static func forward(_ original: Email, asAttachment: Bool, from sender: EmailAddress?) -> MessageDraft {
        let attachments: [DraftAttachment]
        if asAttachment {
            attachments = original.blobId.map { blobId in
                [DraftAttachment(
                    name: messageFileName(subject: original.subject), type: "message/rfc822", size: original.size ?? 0,
                    source: .server(blobId: blobId))]
            } ?? []
        } else {
            attachments = (original.attachments ?? []).compactMap { part in
                guard let blobId = part.blobId, !(part.disposition == "inline" && part.cid != nil) else { return nil }
                let type = part.type ?? "application/octet-stream"
                return DraftAttachment(
                    name: SafeFilename.make(part.name, mimeType: type), type: type, size: part.size ?? 0,
                    source: .server(blobId: blobId))
            }
        }
        return MessageDraft(
            kind: asAttachment ? .forwardAsAttachment : .forward, from: sender,
            subject: forwardSubject(original.subject), attachments: attachments, original: OriginalMessage(original))
    }

    /// One "Re: ", unless the subject already starts with a reply prefix, kept as it is (RFC 5322 §3.6.5).
    public static func replySubject(_ subject: String?) -> String {
        prefixed(subject, with: "Re:", keeping: ["re:", "aw:", "sv:", "antw:"])
    }

    /// One "Fwd: ", unless the subject already starts with a forward prefix.
    public static func forwardSubject(_ subject: String?) -> String {
        prefixed(subject, with: "Fwd:", keeping: ["fwd:", "fw:", "wg:"])
    }

    static func prefixed(_ subject: String?, with prefix: String, keeping prefixes: [String]) -> String {
        let subject = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = subject.lowercased()
        if prefixes.contains(where: lower.hasPrefix) { return subject }
        return subject.isEmpty ? prefix : "\(prefix) \(subject)"
    }

    static func messageFileName(subject: String?) -> String {
        let subject = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = subject.isEmpty ? "Forwarded Message" : subject.replacing(#/[/\\:]/#, with: "-")
        return SafeFilename.make(base + ".eml", mimeType: "message/rfc822")
    }

    /// Addresses in order, each once, compared without case.
    static func unique(_ addresses: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.email.lowercased()).inserted }
    }
}

extension OriginalMessage {
    /// The original's quote snapshot and the inline images its HTML refers to.
    public init(_ email: Email) {
        let inlineParts = email.inlineImageParts.compactMap { part -> InlinePart? in
            guard let cid = part.cid, let blobId = part.blobId else { return nil }
            return InlinePart(cid: cid, blobId: blobId, type: part.type ?? "application/octet-stream", name: part.name)
        }
        self.init(emailID: email.id, blobID: email.blobId, quote: QuotedMessage(email), inlineParts: inlineParts)
    }
}

extension QuotedMessage {
    /// The body as fetched: HTML when the message has an HTML part, text when it has a plain-text one. Both are
    /// nil when no body was fetched.
    public init(_ email: Email) {
        let sender = email.from?.first ?? email.sender?.first
        let htmlParts = email.htmlBody ?? []
        var html: String?
        if htmlParts.contains(where: { $0.type?.lowercased() == "text/html" }) {
            let pieces = htmlParts.compactMap { part -> String? in
                guard let value = Self.value(of: part, in: email) else { return nil }
                return part.type?.lowercased() == "text/html" ? value : MessageAssembler.html(fromPlainText: value)
            }
            html = pieces.isEmpty ? nil : pieces.joined()
        }
        let textParts = (email.textBody ?? []).filter { $0.type?.lowercased() == "text/plain" }
        let texts = textParts.compactMap { Self.value(of: $0, in: email) }
        let used = (htmlParts + textParts).compactMap { $0.partId.flatMap { email.bodyValues?[$0] } }
        self.init(
            fromName: sender?.name.flatMap { $0.isEmpty ? nil : $0 }, fromEmail: sender?.email ?? "",
            to: email.to ?? [], cc: email.cc ?? [], date: email.sentAt ?? email.receivedAt ?? .distantPast,
            subject: email.subject ?? "", html: html, text: texts.isEmpty ? nil : texts.joined(separator: "\n"),
            isTruncated: used.contains { $0.isTruncated })
    }

    static func value(of part: EmailBodyPart, in email: Email) -> String? {
        part.partId.flatMap { email.bodyValues?[$0]?.value }
    }
}
