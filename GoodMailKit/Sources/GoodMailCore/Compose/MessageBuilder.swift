import Foundation
import JMAPKit
import MailCompose

/// Turns a `MessageDraft` into what `Email/set` and `EmailSubmission/set` take (§3.9).
enum MessageBuilder {
    enum Problem: Error, Equatable {
        case noSender
        /// The Message-ID isn't on the From address's domain, so it would tell which other address wrote it (C7).
        case messageIDNotOnSenderDomain
    }

    /// The email for `Email/set`. Drafts and messages to send have the same shape: in Drafts, `$draft` and
    /// `$seen`; a successful submission moves the message to Sent (`onSuccessUpdateEmail`).
    static func email(
        for draft: MessageDraft, body: OutgoingBody, attachments: [EmailBodyPartCreate], draftsMailbox: String,
        sentAt: Date
    ) -> EmailCreate {
        let parts = EmailCreate.body(
            text: body.text, html: body.html, inline: inlineParts(of: draft, contentIDs: body.contentIDs),
            attachments: attachments)
        return EmailCreate(
            mailboxIds: [draftsMailbox: true],
            keywords: [Email.Keyword.draft.rawValue: true, Email.Keyword.seen.rawValue: true],
            messageId: [draft.messageID], inReplyTo: nonEmpty(draft.inReplyTo), references: nonEmpty(draft.references),
            from: draft.from.map { [$0] }, to: nonEmpty(draft.to), cc: nonEmpty(draft.cc), bcc: nonEmpty(draft.bcc),
            replyTo: nonEmpty(draft.replyTo), subject: draft.subject, sentAt: sentAt,
            bodyStructure: parts.structure, bodyValues: parts.values)
    }

    /// Every recipient once, compared without case: To, then Cc, then Bcc.
    static func recipients(of draft: MessageDraft) -> [String] {
        var seen = Set<String>()
        return (draft.to + draft.cc + draft.bcc).map(\.email).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The SMTP envelope: from the From address itself, which keeps a masked address's Return-Path masked
    /// (D20), and held for `holdFor` seconds when given (`HOLDFOR`, RFC 4865, a string of digits).
    static func envelope(for draft: MessageDraft, holdFor seconds: Int?) throws -> EmailSubmission.Envelope {
        guard let from = draft.from?.email else { throw Problem.noSender }
        return EmailSubmission.Envelope(
            mailFrom: EmailSubmission.Address(email: from, parameters: seconds.map { ["HOLDFOR": String($0)] }),
            rcptTo: recipients(of: draft).map { EmailSubmission.Address(email: $0) })
    }

    /// Checks that the Message-ID is on From's domain (D9, C7).
    static func checkMessageID(of draft: MessageDraft) throws {
        guard let from = draft.from?.email else { throw Problem.noSender }
        guard draft.messageIDDomain?.lowercased() == AddressParser.domain(of: from) else {
            throw Problem.messageIDNotOnSenderDomain
        }
    }

    /// The images the quote or preserved tail shows through `cid:` URLs, attached again by blob id inside
    /// `multipart/related`, in the order the HTML refers to them.
    static func inlineParts(of draft: MessageDraft, contentIDs: [String]) -> [EmailBodyPartCreate] {
        let available = (draft.original?.inlineParts ?? []) + (draft.preservedTail?.inlineParts ?? [])
        var seen = Set<String>()
        return contentIDs.compactMap { cid in
            guard seen.insert(cid).inserted, let part = available.first(where: { $0.cid == cid }) else { return nil }
            return .blob(part.blobId, type: part.type, name: part.name, disposition: "inline", cid: part.cid)
        }
    }

    /// An attachment referring to a blob on the server: an upload, or a file of another email.
    static func attachmentPart(_ attachment: DraftAttachment, blobID: String) -> EmailBodyPartCreate {
        .blob(blobID, type: attachment.type, name: attachment.name, disposition: "attachment")
    }

    private static func nonEmpty<T>(_ list: [T]?) -> [T]? {
        list.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Assembles bodies off the main actor and keeps, per draft, everything but the user's own text: sanitizing a
/// long quote takes a while (0.4 s for 4 MB), and autosave assembles a draft again every few seconds.
actor MessageAssembly {
    /// What the part of the body below the user's text depends on.
    private struct Key: Equatable {
        var kind: MessageDraft.Kind
        var includesSignature: Bool
        var signature: Signature?
        var preservedTail: PreservedTail?
        var quote: QuotedMessage?
        var hiddenAddresses: Set<String>
    }

    private struct Entry {
        var key: Key
        var skeleton: OutgoingBody
        var lastUse: Int
    }

    private var entries: [UUID: Entry] = [:]
    private var uses = 0
    private let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    /// The user's text in a skeleton: one paragraph that `splice` can find and replace.
    private static let placeholder = AttributedString("GoodMailAssemblyPlaceholder")
    private static let writtenPlaceholder = MailHTMLWriter.write(placeholder)
    private static let documentStart = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>"
    private static let separator = "<div><br></div>"

    /// The same as `MessageAssembler.assemble(_:options:)`, with `hiddenAddresses` (lower-cased) as the addresses
    /// to keep out of the quote's attribution and forwarded header block.
    func body(for draft: MessageDraft, signature: Signature?, hiddenAddresses: Set<String>) -> OutgoingBody {
        let key = Key(
            kind: draft.kind, includesSignature: draft.includesSignature, signature: signature,
            preservedTail: draft.preservedTail, quote: draft.original?.quote, hiddenAddresses: hiddenAddresses)
        let options = AssemblyOptions(signature: signature, hidesAddress: { hiddenAddresses.contains($0.lowercased()) })
        uses += 1
        let skeleton: OutgoingBody
        if let entry = entries[draft.id], entry.key == key {
            skeleton = entry.skeleton
            entries[draft.id]?.lastUse = uses
        } else {
            var placeholderDraft = draft
            placeholderDraft.body = Self.placeholder
            skeleton = MessageAssembler.assemble(placeholderDraft, options: options)
            entries[draft.id] = Entry(key: key, skeleton: skeleton, lastUse: uses)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                entries[oldest.key] = nil
            }
        }
        return Self.splice(draft.body, into: skeleton) ?? MessageAssembler.assemble(draft, options: options)
    }

    func forget(_ id: UUID) {
        entries[id] = nil
    }

    /// The skeleton with the placeholder paragraph replaced by `body`, or removed for an empty body the way the
    /// assembler leaves an empty body out; `nil` if the skeleton isn't laid out as expected.
    static func splice(_ body: AttributedString, into skeleton: OutgoingBody) -> OutgoingBody? {
        let placeholder = writtenPlaceholder
        let start = documentStart + placeholder.html
        guard skeleton.html.hasPrefix(start), skeleton.text.hasPrefix(placeholder.text) else { return nil }
        var result = skeleton
        let afterHTML = skeleton.html.dropFirst(start.count)
        let afterText = skeleton.text.dropFirst(placeholder.text.count)
        if body.characters.isEmpty {
            let html = afterHTML.hasPrefix(separator) ? afterHTML.dropFirst(separator.count) : afterHTML
            let text = afterText.hasPrefix("\n\n") ? afterText.dropFirst(2) : afterText
            result.html = documentStart + html
            result.text = String(text)
        } else {
            let own = MailHTMLWriter.write(body)
            result.html = documentStart + own.html + afterHTML
            result.text = own.text + afterText
        }
        return result
    }
}
