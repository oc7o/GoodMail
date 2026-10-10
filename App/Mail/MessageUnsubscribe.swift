import GoodMailCore
import JMAPKit
import MailPrivacy
import SwiftUI

/// The mailing-list row of a message (§2.6, §5.7): the ways its list offers to unsubscribe, asked for from
/// Fastmail when the message is shown, and what came of the last request. Not for Junk or phishing.
struct MessageUnsubscribeRow: View {
    let email: Email

    @Environment(MailAccount.self) private var account
    @State private var offer: UnsubscribeOffer?

    var body: some View {
        Group {
            if let offer {
                let mail = account.mail
                let mask = offer.maskedAddress.map { mask in mail.maskedEmails.first { $0.id == mask.id } ?? mask }
                let sender = mail.sender(for: email)?.address
                let senderNeedsIdentity = Self.needsSendingIdentity(sender, in: mail)
                UnsubscribeControl(
                    listName: offer.listName, methods: offer.methods, maskedAddress: mask?.email,
                    isMaskDisabled: mask?.state == .disabled, previousDate: offer.previousRequestDate,
                    // Nothing asks for identity consent while GoodMail may not create identities (Q3).
                    mailtoNeedsIdentityConsent: MaskedSendPolicy.createsIdentities && senderNeedsIdentity,
                    mailtoSenderMissing: !MaskedSendPolicy.createsIdentities && senderNeedsIdentity,
                    perform: { method in await perform(method, offer: offer, sender: sender) },
                    disableMask: mask.map { mask in { await disable(mask, offer: offer) } })
            }
        }
        .task(id: email.id) { offer = await Self.offer(for: email, in: account) }
    }

    static func offer(for email: Email, in account: MailAccount) async -> UnsubscribeOffer? {
        guard email.listUnsubscribe?.isEmpty == false else { return nil }
        let mail = account.mail
        let isJunk = mail.mailbox(.junk).map { email.mailboxIds?[$0.id] == true } ?? false
        return await account.unsubscriber.offer(for: email, isJunk: isJunk, deliveredTo: mail.maskedEmail(for: email))
    }

    /// A masked sender that Fastmail has no sending identity for (D21); unknown identities claim nothing.
    static func needsSendingIdentity(_ sender: EmailAddress?, in mail: MailModel) -> Bool {
        guard let sender, !mail.identities.isEmpty else { return false }
        return mail.senderOptions().first { $0.id == sender.email.lowercased() }?.needsSendingIdentity == true
    }

    private func perform(_ method: ListUnsubscribe.Method, offer: UnsubscribeOffer, sender: EmailAddress?) async -> String? {
        let outbox = account.mail.outbox
        let outcome = await account.unsubscriber.unsubscribe(offer, using: method, from: sender) { draft in
            try await outbox.send(draft)
        }
        return Self.status(of: outcome)
    }

    private func disable(_ mask: MaskedEmail, offer: UnsubscribeOffer) async {
        await account.mail.setMaskedEmailState(.disabled, id: mask.id)
        await account.unsubscriber.recordMaskDisabled(offer)
    }

    /// The row's status line after an attempt (§3.10).
    static func status(of outcome: UnsubscribeOutcome) -> String? {
        switch outcome {
        case .requested:
            "Unsubscribe requested – lists can take a few days to stop."
        case .requestedButRedirected:
            "The list answered with a redirect, which GoodMail doesn't follow. If its mail keeps coming, use its "
                + "unsubscribe page."
        case .mailQueued:
            "The unsubscribe email is on its way; see the Outbox."
        case .openPage:
            "Unsubscribe page opened."
        case .refusedTarget:
            "This list's unsubscribe address points into a private network. Use its web page instead."
        case .failed(let reason):
            reason + " Unsubscribe offers the list's other ways."
        }
    }
}

/// The unsubscribe row on its own, for the reading pane's More menu and the list's context menu (§5.7).
struct UnsubscribeSheet: View {
    let email: Email
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(email.subject?.nonEmpty ?? "(No Subject)")
                    .font(.headline)
                    .lineLimit(2)
                MessageUnsubscribeRow(email: email)
                    .padding(12)
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Unsubscribe")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 220)
        #else
        .presentationDetents([.height(260), .medium])
        #endif
    }
}

extension Email {
    /// Whether the message names a mailing list to leave, as far as its stored properties tell.
    var offersUnsubscribe: Bool {
        listUnsubscribe?.isEmpty == false && !has(.phishing)
    }
}
