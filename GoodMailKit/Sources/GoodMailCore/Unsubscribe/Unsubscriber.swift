import Foundation
import JMAPKit
import MailCompose
import MailPrivacy
import MailStore

/// The ways to leave the mailing list a message came from.
public struct UnsubscribeOffer: Sendable, Equatable {
    /// The list for people: the sender's name, else the List-Id's description, else an address.
    public var listName: String
    /// What requests are remembered by: the List-Id, else the sender's address, lower-cased.
    public var listKey: String
    /// In preference order (`ListUnsubscribe.methods`).
    public var methods: [ListUnsubscribe.Method]
    /// The masked address the message was delivered to; disabling it is the other way out.
    public var maskedAddress: MaskedEmail?
    /// The last request for this list.
    public var previous: Unsubscription?

    public init(
        listName: String, listKey: String, methods: [ListUnsubscribe.Method], maskedAddress: MaskedEmail? = nil,
        previous: Unsubscription? = nil
    ) {
        self.listName = listName
        self.listKey = listKey
        self.methods = methods
        self.maskedAddress = maskedAddress
        self.previous = previous
    }

    /// When the last request was made, unless it failed: the date of "Unsubscribe requested on 9 Oct".
    public var previousRequestDate: Date? {
        guard let previous, !previous.outcome.hasPrefix(Unsubscriber.failedPrefix) else { return nil }
        return previous.requestedAt
    }
}

public enum UnsubscribeOutcome: Sendable, Equatable {
    /// The list's server accepted the one-click request.
    case requested
    /// The list's server answered with a redirect, which isn't followed (D27).
    case requestedButRedirected
    /// The unsubscribe message waits in the outbox.
    case mailQueued
    /// The list's unsubscribe page, for a private web view.
    case openPage(URL)
    /// The one-click address leads somewhere other than the public internet, so nothing was sent.
    case refusedTarget
    /// The text says why, for people.
    case failed(String)
}

/// Unsubscribing from mailing lists (§2.6): one-click (RFC 8058) where Fastmail's verdicts vouch for the list's
/// headers (D26), else a message to the list, else its web page; and a record of each request.
@MainActor
public final class Unsubscriber {
    nonisolated static let failedPrefix = "failed:"

    private let client: JMAPClient
    private let store: MailStore
    private let oneClick: any HTTPTransport
    private let receiver: ListUnsubscribe.Receiver
    private let resolver: any HostResolver

    /// - Parameters:
    ///   - oneClick: Where one-click requests go: a session of their own, never `JMAPClient`'s (D27).
    ///   - receiver: Whose Authentication-Results can vouch for a list's headers.
    ///   - resolver: Checks that a one-click host resolves to public addresses only.
    public init(
        client: JMAPClient, store: MailStore,
        oneClick: any HTTPTransport = URLSessionTransport(session: Unsubscriber.makeOneClickSession()),
        receiver: ListUnsubscribe.Receiver = .fastmail, resolver: any HostResolver = SystemHostResolver()
    ) {
        self.client = client
        self.store = store
        self.oneClick = oneClick
        self.receiver = receiver
        self.resolver = resolver
    }

    /// How to unsubscribe from the list of `email`, or `nil` if it offers no way, or the email is in Junk
    /// (`isJunk`) or marked as phishing.
    ///
    /// The header fields come from the server, which is the only way to learn whether one-click can be trusted.
    /// Without it, only the ways that ask the user to act are offered, from the stored `listUnsubscribe`.
    ///
    /// - Parameter mask: The masked address the email was delivered to, if any.
    public func offer(for email: Email, isJunk: Bool, deliveredTo mask: MaskedEmail?) async -> UnsubscribeOffer? {
        guard !isJunk, !email.has(.phishing) else { return nil }
        let headers = try? await client.unsubscribeHeaders(emailID: email.id)
        let methods: [ListUnsubscribe.Method] = if let headers {
            ListUnsubscribe.methods(
                listUnsubscribe: headers.listUnsubscribe, listUnsubscribePost: headers.listUnsubscribePost,
                headers: headers.headers.map { ListUnsubscribe.HeaderField(name: $0.name, value: $0.value) },
                receiver: receiver)
        } else {
            ListUnsubscribe.fallbackMethods(listUnsubscribe: email.listUnsubscribe ?? [])
        }
        let listID = Self.listID(headers?.listId ?? email.listId)
        let sender = email.from?.first
        guard !methods.isEmpty, let listKey = (listID?.id ?? sender?.email)?.lowercased() else { return nil }
        let previous = (try? await store.unsubscription(listKey: listKey)) ?? nil
        return UnsubscribeOffer(
            listName: Self.listName(sender: sender, listID: listID), listKey: listKey, methods: methods,
            maskedAddress: mask, previous: previous)
    }

    /// The message for a `mailto:` method: plain text without a signature or display name, from `sender`, which
    /// should be the address the list mail arrived at.
    public func mailtoDraft(_ link: MailtoLink, from sender: EmailAddress) -> MessageDraft {
        MessageDraft(
            from: EmailAddress(email: sender.email), to: link.to.map { EmailAddress(email: $0) },
            subject: link.subject ?? "unsubscribe", body: AttributedString(link.body ?? ""), includesSignature: false)
    }

    /// Unsubscribes with `method`, which the user confirmed, and records the outcome.
    ///
    /// - Parameters:
    ///   - sender: For a `mailto:` method: the address the list mail arrived at.
    ///   - sendMail: Queues the `mailto:` message, e.g. in the outbox; what it throws becomes `.failed`.
    public func unsubscribe(
        _ offer: UnsubscribeOffer, using method: ListUnsubscribe.Method, from sender: EmailAddress?,
        sendMail: (MessageDraft) async throws -> Void
    ) async -> UnsubscribeOutcome {
        let outcome: UnsubscribeOutcome
        switch method {
        case .oneClick(let url):
            outcome = await postOneClick(to: url)
        case .mailto(let link):
            if let sender {
                do {
                    try await sendMail(mailtoDraft(link, from: sender))
                    outcome = .mailQueued
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
            } else {
                outcome = .failed("There's no address to send the unsubscribe message from.")
            }
        case .web(let url):
            outcome = .openPage(url)
        }
        await record(outcome, method: Self.storedName(of: method), for: offer)
        return outcome
    }

    /// Records that the masked address the list writes to was disabled instead.
    public func recordMaskDisabled(_ offer: UnsubscribeOffer) async {
        try? await store.recordUnsubscription(
            Unsubscription(listKey: offer.listKey, method: "disableMask", requestedAt: Date(), outcome: "requested"))
    }

    // MARK: One-click

    private func postOneClick(to url: URL) async -> UnsubscribeOutcome {
        guard UnsubscribeTarget.isAllowed(url), let host = url.host(percentEncoded: false) else {
            return .refusedTarget
        }
        // DNS may answer differently once URLSession asks again (rebinding); the fixed body and the user's
        // confirmation limit what that could do.
        do {
            let addresses = try await resolver.addresses(of: host)
            guard !addresses.isEmpty, addresses.allSatisfy(UnsubscribeTarget.isPublic(address:)) else {
                return .refusedTarget
            }
        } catch {
            return .failed("Couldn't find the list's server.")
        }
        do {
            let (_, response) = try await oneClick.send(Self.oneClickRequest(to: url))
            switch response.statusCode {
            case 200..<300: return .requested
            case 300..<400: return .requestedButRedirected
            default: return .failed("The list didn't accept the request (HTTP \(response.statusCode)).")
            }
        } catch {
            return .failed("Couldn't reach the list's server.")
        }
    }

    // MARK: Records

    private func record(_ outcome: UnsubscribeOutcome, method: String, for offer: UnsubscribeOffer) async {
        let recorded = switch outcome {
        case .requested, .openPage: "requested"
        case .requestedButRedirected: "redirected"
        case .mailQueued: "queued"
        case .refusedTarget: Self.failedPrefix + "not a public address"
        case .failed(let detail): Self.failedPrefix + detail
        }
        try? await store.recordUnsubscription(
            Unsubscription(listKey: offer.listKey, method: method, requestedAt: Date(), outcome: recorded))
    }

    private static func storedName(of method: ListUnsubscribe.Method) -> String {
        switch method {
        case .oneClick: "oneClick"
        case .mailto: "mailto"
        case .web: "web"
        }
    }

    // MARK: List-Id

    /// RFC 2919: `List-Id: [phrase] <list-id>`, read leniently.
    static func listID(_ value: String?) -> (id: String, phrase: String?)? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") else {
            return (value, nil)
        }
        let id = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        let phrase = value[..<open].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return (id, phrase.isEmpty ? nil : phrase)
    }

    static func listName(sender: EmailAddress?, listID: (id: String, phrase: String?)?) -> String {
        if let name = sender?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let phrase = listID?.phrase { return phrase }
        return sender?.email ?? listID?.id ?? "Mailing list"
    }
}
