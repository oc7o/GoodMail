import GoodMailCore
import JMAPKit
import MailPrivacy
import SwiftUI

/// One message of a conversation: a header that expands into the privacy bar, body and attachments.
struct MessageView: View {
    let model: MailModel
    let email: Email
    let isExpanded: Bool
    let toggle: () -> Void

    @Environment(MailAccount.self) private var account
    @Environment(\.compose) private var compose
    @State private var policy = RemoteContentPolicy.blockAll
    @State private var rendered: RenderedMessage?
    @State private var height: CGFloat = 40

    private struct RenderKey: Equatable {
        let isExpanded: Bool
        let policy: RemoteContentPolicy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Button(action: toggle) { header }
                    .buttonStyle(.plain)
                if isExpanded {
                    actions
                        .padding([.top, .trailing], 10)
                }
            }
            if isExpanded {
                if let masked = model.maskedEmail(for: email) {
                    MaskedEmailBadge(model: model, masked: masked)
                        .padding([.horizontal, .bottom], 12)
                }
                if email.offersUnsubscribe {
                    MessageUnsubscribeRow(email: email)
                        .padding([.horizontal, .bottom], 12)
                }
                if let rendered {
                    privacyBar(rendered)
                    Divider()
                    MessageWebView(html: rendered.html, policy: policy, height: $height) { cid in
                        await model.inlineImage(cid: cid, in: email).map { ($0.data, $0.type) }
                    }
                    .frame(height: height)
                    .environment(\.openURL, mailtoAction)
                }
                attachments
            }
        }
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .task(id: RenderKey(isExpanded: isExpanded, policy: policy)) {
            guard isExpanded else { return }
            rendered = MessageRenderer.render(email.messageParts, policy: policy)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            let sender = email.from?.first
            Text(sender?.initials.nonEmpty ?? "?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender?.displayName ?? "(No Sender)")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if email.has(.draft) {
                        Text("Draft")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 8)
                    if let date = email.receivedAt {
                        Text(isExpanded ? date.formatted(date: .abbreviated, time: .shortened) : date.listTimestamp)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if isExpanded {
                    if let address = sender?.email, address != sender?.displayName {
                        Text(address)
                    }
                    Text("To: \(recipients)")
                        .lineLimit(2)
                } else {
                    Text(email.preview ?? "")
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .contentShape(.rect)
    }

    /// Reply, Reply All and Forward for this message; Edit Draft for a draft (§5.8).
    @ViewBuilder private var actions: some View {
        if email.has(.draft) {
            Button("Edit Draft", systemImage: "square.and.pencil") { compose(.draft(emailID: email.id)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Menu {
                MessageActions(emailID: email.id)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Reply, Reply All or Forward")
        }
    }

    /// `mailto:` links open the composer, replying from the address this message came to (C8, D31); every other
    /// link opens as before.
    private var mailtoAction: OpenURLAction {
        let compose = compose
        let emailID = email.id
        return OpenURLAction { url in
            guard url.scheme?.lowercased() == "mailto", let link = MailtoLink(url) else { return .systemAction }
            compose(.mailto(link, sourceEmailID: emailID))
            return .handled
        }
    }

    private var recipients: String {
        ((email.to ?? []) + (email.cc ?? [])).map(\.displayName).joined(separator: ", ")
    }

    @ViewBuilder private func privacyBar(_ rendered: RenderedMessage) -> some View {
        let blocksImages = policy == .blockAll && rendered.remoteImageCount > 0
        if blocksImages || rendered.trackerCount > 0 || isTruncated {
            VStack(alignment: .leading, spacing: 6) {
                if rendered.trackerCount > 0 {
                    Label(
                        "\(rendered.trackerCount) tracker\(rendered.trackerCount == 1 ? "" : "s") removed",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .foregroundStyle(.green)
                }
                if blocksImages {
                    HStack {
                        Label("Remote images are blocked", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Load Images") { policy = .allowImages }
                            .controlSize(.small)
                    }
                }
                if isTruncated {
                    Label("This message is too long to show in full", systemImage: "scissors")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding([.horizontal, .bottom], 12)
        }
    }

    private var isTruncated: Bool {
        email.bodyValues?.values.contains { $0.isTruncated } ?? false
    }

    /// The files of the message, from the account's attachment store: Quick Look, Save…, Share (D23).
    @ViewBuilder private var attachments: some View {
        let files = email.fileAttachments
        if !files.isEmpty {
            Divider()
            AttachmentStrip(parts: files, actions: account.attachments)
        }
    }
}

/// Reply, Reply All, Forward and Forward as Attachment for one message.
struct MessageActions: View {
    let emailID: String
    @Environment(\.compose) private var compose

    var body: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(emailID: emailID, all: false)) }
        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { compose(.reply(emailID: emailID, all: true)) }
        Button("Forward", systemImage: "arrowshape.turn.up.right") {
            compose(.forward(emailID: emailID, asAttachment: false))
        }
        Button("Forward as Attachment", systemImage: "paperclip") {
            compose(.forward(emailID: emailID, asAttachment: true))
        }
    }
}

extension Email {
    /// The parts to show as the message body, in order.
    var messageParts: [MessagePart] {
        (htmlBody ?? []).compactMap { part in
            guard let id = part.partId, let value = bodyValues?[id]?.value else { return nil }
            return MessagePart(kind: part.type == "text/html" ? .html : .plainText, content: value)
        }
    }

    /// Attached files, without the images the body shows inline.
    var fileAttachments: [EmailBodyPart] {
        (attachments ?? []).filter { !($0.disposition == "inline" && $0.cid != nil) }
    }
}
