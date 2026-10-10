import Foundation
import JMAPKit
import MailCompose

/// The address a reply or new message goes out from, and why it was picked (D19).
public struct SenderChoice: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The original came from one of the user's own addresses: a follow-up keeps it.
        case originalFromYou
        /// The original reached a masked address.
        case deliveredToMask
        /// The original reached an identity's address (a wildcard identity's included).
        case deliveredToIdentity
        case defaultIdentity
        /// No identity is known, so the login name.
        case loginName
    }

    public var address: EmailAddress
    public var reason: Reason

    public init(address: EmailAddress, reason: Reason) {
        self.address = address
        self.reason = reason
    }
}

/// One entry of the From menu.
public struct SenderOption: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case identity(id: String)
        case masked(id: String, state: MaskedEmail.State)
        /// The login name, offered when no identity is known.
        case login
    }

    public var address: EmailAddress
    public var kind: Kind
    /// A masked address Fastmail has no sending identity for, which it won't send from (D21).
    public var needsSendingIdentity: Bool
    public var id: String { address.email.lowercased() }

    public init(address: EmailAddress, kind: Kind, needsSendingIdentity: Bool) {
        self.address = address
        self.kind = kind
        self.needsSendingIdentity = needsSendingIdentity
    }
}

/// How GoodMail sends from a masked address (D21).
public enum MaskedSendPolicy {
    /// Sending a masked From under the default identity: Fastmail refuses it (`forbiddenMailFrom`, send probe
    /// round 1), so a masked send always needs an identity of its own or a wildcard one for its domain.
    public static let usesDefaultIdentity = false
    /// Whether GoodMail creates a sending identity for a masked address that has none, with the user's consent
    /// for that exact address. Off until the user decides (Q3); while off, nothing asks for that consent.
    public static let createsIdentities = false
}

/// `MaskedSendPolicy` as the outbox applies it; tests can turn creating identities on.
struct MaskedSending: Sendable, Equatable {
    var usesDefaultIdentity = MaskedSendPolicy.usesDefaultIdentity
    var createsIdentities = MaskedSendPolicy.createsIdentities
}

/// The user's own addresses: identities (wildcards included), masked addresses and the login name.
struct SenderDirectory: Sendable {
    var login: String?
    var identities: [Identity] = []
    var hiddenIdentityIDs: Set<String> = []
    /// By lower-cased address.
    var maskedEmails: [String: MaskedEmail] = [:]

    func maskedEmail(_ address: String) -> MaskedEmail? {
        maskedEmails[address.lowercased()]
    }

    func isMasked(_ address: String) -> Bool {
        maskedEmail(address) != nil
    }

    /// The identity that sends `address`: one with exactly that address, preferring one Fastmail shows in
    /// compose, else a wildcard identity for its domain.
    func identity(for address: String) -> Identity? {
        let exact = identities.filter { !$0.isWildcard && $0.matches(address) }
        return exact.first { !hiddenIdentityIDs.contains($0.id) } ?? exact.first
            ?? identities.first { $0.isWildcard && $0.matches(address) }
    }

    /// The identity whose address is the login name, else the first one that can't be deleted.
    var defaultIdentity: Identity? {
        let login = login?.lowercased()
        return identities.first { !$0.isWildcard && $0.email.lowercased() == login }
            ?? identities.first { !$0.isWildcard && !$0.mayDelete }
    }

    /// Whether `address` is the user's: an identity's (wildcards included), a masked address, the login name,
    /// or one of `deliveredTo`, the addresses Fastmail delivered the original to.
    func isOwn(_ address: String, deliveredTo: [String] = []) -> Bool {
        let address = address.lowercased()
        return address == login?.lowercased() || isMasked(address)
            || identities.contains { $0.matches(address) } || deliveredTo.contains { $0.lowercased() == address }
    }

    /// From for sending from `address`: the identity's name, none for a masked address (D20).
    func fromAddress(_ address: String) -> EmailAddress {
        guard !isMasked(address), let name = identity(for: address)?.name, !name.isEmpty else {
            return EmailAddress(email: address)
        }
        return EmailAddress(name: name, email: address)
    }

    /// D19, checked in order: the original's From when it is the user's; a masked address it reached
    /// (X-Delivered-To first); an identity it reached (To and Cc first); the default identity; the login.
    func sender(for original: Email?) -> SenderChoice? {
        if let original {
            let deliveredTo = original.deliveredToAddresses.map(\.email)
            let toAndCc = ((original.to ?? []) + (original.cc ?? [])).map(\.email)
            let bcc = (original.bcc ?? []).map(\.email)
            if let own = original.from?.first(where: { isOwn($0.email) }) {
                return SenderChoice(address: fromAddress(own.email), reason: .originalFromYou)
            }
            if let masked = (deliveredTo + toAndCc + bcc).first(where: isMasked) {
                return SenderChoice(address: fromAddress(masked), reason: .deliveredToMask)
            }
            if let address = (toAndCc + deliveredTo + bcc).first(where: { identity(for: $0) != nil }) {
                return SenderChoice(address: fromAddress(address), reason: .deliveredToIdentity)
            }
        }
        if let identity = defaultIdentity {
            return SenderChoice(address: fromAddress(identity.email), reason: .defaultIdentity)
        }
        if let login, !login.isEmpty {
            return SenderChoice(address: EmailAddress(email: login), reason: .loginName)
        }
        return nil
    }

    /// The From menu: identities Fastmail shows in compose, then masked addresses (enabled ones first, deleted
    /// ones left out), then the login name if no identity is known. Each address once.
    func options() -> [SenderOption] {
        var options = identities
            .filter { !$0.isWildcard && !hiddenIdentityIDs.contains($0.id) && !isMasked($0.email) }
            .map { SenderOption(address: fromAddress($0.email), kind: .identity(id: $0.id), needsSendingIdentity: false) }
        let order: [MaskedEmail.State] = [.enabled, .pending, .disabled]
        options += maskedEmails.values
            .filter { order.contains($0.state) }
            .sorted { (order.firstIndex(of: $0.state)!, $0.email) < (order.firstIndex(of: $1.state)!, $1.email) }
            .map { masked in
                SenderOption(
                    address: EmailAddress(email: masked.email), kind: .masked(id: masked.id, state: masked.state),
                    needsSendingIdentity: identity(for: masked.email) == nil)
            }
        if identities.isEmpty, let login, !login.isEmpty {
            options.append(SenderOption(address: EmailAddress(email: login), kind: .login, needsSendingIdentity: false))
        }
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }

    enum SendingIdentity: Equatable {
        case identity(Identity)
        /// A masked address without an identity, for which the user agreed to create one.
        case create(String)
        /// A masked address Fastmail won't send from as things are (D21).
        case missingForMask(String)
        /// An address that is none of the user's sending addresses.
        case notAllowed(String)
    }

    /// Whether sending from `address` takes a sending identity Fastmail doesn't have yet: a masked address with
    /// no identity of its own or for its domain (D21).
    func needsSendingIdentity(for address: String, policy: MaskedSending) -> Bool {
        isMasked(address) && identity(for: address) == nil && !(policy.usesDefaultIdentity && defaultIdentity != nil)
    }

    /// How to send from `address`, given the consent the user gave for an exact address (C24).
    func sendingIdentity(for address: String, consent: String?, policy: MaskedSending) -> SendingIdentity {
        if let identity = identity(for: address) { return .identity(identity) }
        guard isMasked(address) else { return .notAllowed(address) }
        if policy.usesDefaultIdentity, let identity = defaultIdentity { return .identity(identity) }
        if policy.createsIdentities, consent?.lowercased() == address.lowercased() { return .create(address) }
        return .missingForMask(address)
    }

    /// The signature for sending from `address`: its identity's, none on masked sends (D6).
    func signature(for address: String?) -> Signature? {
        guard let address, !isMasked(address), let identity = identity(for: address) else { return nil }
        let signature = Signature(html: identity.htmlSignature, text: identity.textSignature)
        return signature.isEmpty ? nil : signature
    }
}

extension MailModel {
    var senderDirectory: SenderDirectory {
        SenderDirectory(
            login: username ?? account?.username, identities: identities,
            hiddenIdentityIDs: Set(account?.hiddenIdentityIDs ?? []), maskedEmails: maskedEmailsByAddress)
    }

    /// Whether `address` is the user's: an identity's (wildcards included), a masked address, the login name,
    /// or an address `original` was delivered to (its X-Delivered-To).
    public func isOwnAddress(_ address: String, in original: Email? = nil) -> Bool {
        senderDirectory.isOwn(address, deliveredTo: original?.deliveredToAddresses.map(\.email) ?? [])
    }

    /// The address to reply to `original` from, or to write a new message from when it is `nil` (D19).
    public func sender(for original: Email?) -> SenderChoice? {
        senderDirectory.sender(for: original)
    }

    public func senderOptions() -> [SenderOption] {
        senderDirectory.options()
    }
}
