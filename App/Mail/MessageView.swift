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

    @State private var policy = RemoteContentPolicy.blockAll
    @State private var rendered: RenderedMessage?
    @State private var height: CGFloat = 40

    private struct RenderKey: Equatable {
        let isExpanded: Bool
        let policy: RemoteContentPolicy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { header }
                .buttonStyle(.plain)
            if isExpanded {
                if let masked = model.maskedEmail(for: email) {
                    MaskedEmailBadge(model: model, masked: masked)
                        .padding([.horizontal, .bottom], 12)
                }
                if let rendered {
                    privacyBar(rendered)
                    Divider()
                    MessageWebView(html: rendered.html, policy: policy, height: $height) { cid in
                        await inlineImage(cid)
                    }
                    .frame(height: height)
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

    @ViewBuilder private var attachments: some View {
        let files = (email.attachments ?? []).filter { !($0.disposition == "inline" && $0.cid != nil) }
        if !files.isEmpty {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        Label {
                            Text(file.name ?? "Attachment")
                            if let size = file.size {
                                Text(Int64(size), format: .byteCount(style: .file))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "paperclip")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: .capsule)
                    }
                }
                .padding(12)
            }
        }
    }

    private func inlineImage(_ cid: String) async -> (data: Data, mimeType: String)? {
        let parts = (email.attachments ?? []) + (email.htmlBody ?? [])
        guard let part = parts.first(where: { $0.cid == cid }), let blobId = part.blobId,
              let type = part.type, type.hasPrefix("image/"),
              let data = try? await model.client.download(blobId: blobId, type: type, name: part.name ?? "image")
        else { return nil }
        return (data, type)
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
}
