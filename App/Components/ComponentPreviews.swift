#if DEBUG
import JMAPKit
import MailCompose
import MailPrivacy
import SwiftUI

/// Sample content for the component previews (and the offscreen render harness, which shows the same states).
/// Addresses use reserved example domains, so nothing here could reach a real person.
enum ComponentSamples {
    static let body: AttributedString = {
        var text = AttributedString(
            "Hi Maya,\n\nthanks for the photos! Two things for Thursday:\n• the boat leaves at 9\n• bring the map\n\n"
                + "Details are on the trip page. See you there,\nAlex")
        func format(_ phrase: String, _ change: (inout AttributedString, inout AttributedTextSelection) -> Void) {
            guard let range = text.range(of: phrase) else { return }
            var selection = AttributedTextSelection(range: range)
            change(&text, &selection)
        }
        format("thanks for the photos!") {
            $0.updateFont({ $0.isBold = true }, selection: &$1, in: MailFontStyle.context)
        }
        format("Thursday") {
            $0.setColor(MailPalette.colors[3], selection: &$1)
            $0.setUnderline(true, selection: &$1)
        }
        format("at 9") { $0.updateFont({ $0.isItalic = true }, selection: &$1, in: MailFontStyle.context) }
        format("trip page") {
            $0.setLink(URL(string: "https://fjord-outdoor.example/trips/42?ref=alex"), selection: &$1)
        }
        return text
    }()

    static let recipients: [EmailAddress] = [
        EmailAddress(name: "Maya Lindqvist", email: "maya@lindqvist.example"),
        EmailAddress(name: nil, email: "fjord.k3x9@fastmail.example"),
        EmailAddress(name: "Jonas", email: "jonas@"),
    ]

    static let maskedAddresses: Set<String> = ["fjord.k3x9@fastmail.example"]

    static let suggestions: [AddressSuggestion] = [
        AddressSuggestion(address: EmailAddress(name: "Maja Berg", email: "maja@berg.example"), detail: "Berg Design",
                          source: .contacts),
        AddressSuggestion(address: EmailAddress(name: "Mats Holm", email: "mats.holm@example.org"), source: .both),
        AddressSuggestion(address: EmailAddress(name: nil, email: "marta@fjord-outdoor.example"),
                          source: .correspondent),
    ]

    static func suggestions(for query: String) -> [AddressSuggestion] {
        let query = query.lowercased()
        return suggestions.filter {
            $0.address.email.lowercased().contains(query) || ($0.address.name?.lowercased().contains(query) ?? false)
        }
    }

    static let quoteTitle = "On 9 Oct 2026 at 14:03 UTC, Maya Lindqvist <maya@lindqvist.example> wrote:"
    static let quoteHTML = """
        <p>Hi Alex,</p><p>here are the photos from the weekend. The one from the ridge is my favourite.</p>\
        <p>Shall we plan the boat trip for <b>Thursday</b>?</p><p>Maya</p>
        """
    static let signatureHTML = "<div>Alex Berg<br><a href=\"https://berg.example\">berg.example</a></div>"
    static let signatureText = "Alex Berg\nhttps://berg.example"

    /// Received attachments, decoded the way they arrive from Fastmail (JMAP `EmailBodyPart`).
    static let parts: [EmailBodyPart] = {
        let json = """
            [{"blobId": "sample-invoice", "size": 52341, "name": "Invoice 2026-10.pdf", "type": "application/pdf",
              "disposition": "attachment"},
             {"blobId": "sample-photo", "size": 2483021, "name": "Ridge at sunrise.jpeg", "type": "image/jpeg",
              "disposition": "attachment"},
             {"blobId": "sample-report", "size": 1204512, "name": "Trip report with a very long name, final v3.docx",
              "type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
              "disposition": "attachment"}]
            """
        return (try? JSONDecoder().decode([EmailBodyPart].self, from: Data(json.utf8))) ?? []
    }()

    static let oneClickMethods: [ListUnsubscribe.Method] = [
        .oneClick(URL(string: "https://lists.fjord-outdoor.example/unsubscribe/one-click/8f3a")!),
        .mailto(MailtoLink(to: ["unsubscribe@lists.fjord-outdoor.example"], subject: "unsubscribe")),
        .web(URL(string: "https://lists.fjord-outdoor.example/preferences/8f3a")!),
    ]

    static let mailtoMethods: [ListUnsubscribe.Method] = [
        .mailto(MailtoLink(to: ["leave-8f3a@lists.fjord-outdoor.example"], subject: "unsubscribe",
                           body: "Please remove me.")),
    ]

    static let webMethods: [ListUnsubscribe.Method] = [
        .web(URL(string: "https://lists.fjord-outdoor.example/preferences/8f3a")!),
    ]

    /// A page that needs no network, for the private web sheet's preview.
    static let unsubscribePage = URL(
        string: "data:text/html,%3Ch1%3EUnsubscribe%3C/h1%3E%3Cp%3EYou%20are%20unsubscribed.%3C/p%3E")!
}

/// An attachment store stand-in: one file cached, one downloading, nothing ever written to disk.
@MainActor final class SampleAttachmentActions: AttachmentActions {
    var cached: Set<String> = ["sample-photo"]
    var downloads: [String: AttachmentProgress] = [
        "sample-report": AttachmentProgress(received: 420_000, expected: 1_204_512),
    ]

    func isCached(_ part: EmailBodyPart) async -> Bool { cached.contains(part.blobId ?? "") }
    func previewURL(for part: EmailBodyPart) async throws -> URL { throw CocoaError(.featureUnsupported) }
    func release(_ url: URL) {}
    func data(for part: EmailBodyPart) async throws -> Data { throw CocoaError(.featureUnsupported) }
    func attachmentProgress(blobId: String) -> AttachmentProgress? { downloads[blobId] }
    func write(_ part: EmailBodyPart, to destination: URL) async throws { throw CocoaError(.featureUnsupported) }
}

#Preview("Body editor") {
    @Previewable @State var text = ComponentSamples.body
    @Previewable @State var selection = AttributedTextSelection()
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ComposeBodyEditor(text: $text, selection: $selection) { _ in }
            ReadOnlyMessageBlock(title: nil, html: ComponentSamples.signatureHTML, text: nil,
                                 isCollapsible: false) { _ in nil }
                .opacity(0.7)
            ReadOnlyMessageBlock(title: ComponentSamples.quoteTitle, html: ComponentSamples.quoteHTML, text: nil,
                                 isCollapsible: true) { _ in nil }
        }
        .padding()
    }
    #if os(macOS)
    .safeAreaBar(edge: .bottom) {
        FormattingBar(text: $text, selection: $selection)
    }
    #else
    .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
            FormattingControls(text: $text, selection: $selection)
        }
    }
    #endif
}

#Preview("Link editor") {
    LinkEditor(url: URL(string: "https://fjord-outdoor.example/trips/42?ref=alex")) { _ in }
}

#Preview("Recipients") {
    @Previewable @State var to = ComponentSamples.recipients
    @Previewable @State var toEntry = ""
    @Previewable @State var cc: [EmailAddress] = []
    VStack(alignment: .leading, spacing: 12) {
        RecipientField("To:", recipients: $to, entry: $toEntry, suggestions: { ComponentSamples.suggestions(for: $0) },
                       contactsPrompt: ContactsPrompt(access: .notDetermined, request: {}),
                       isMasked: { ComponentSamples.maskedAddresses.contains($0) })
        Divider()
        RecipientField("Cc:", recipients: $cc, suggestions: { ComponentSamples.suggestions(for: $0) },
                       contactsPrompt: nil, isMasked: { _ in false })
    }
    .padding()
    .frame(width: 520)
}

#Preview("Attachment chips") {
    VStack(alignment: .leading, spacing: 8) {
        AttachmentChip(name: "Invoice 2026-10.pdf", size: 52_341, typeIdentifier: "com.adobe.pdf", state: .ready) {}
        AttachmentChip(name: "Ridge at sunrise.jpeg", size: 2_483_021, typeIdentifier: "public.jpeg",
                       state: .uploading(0.4)) {}
        AttachmentChip(name: "Trip report.docx", size: 1_204_512, typeIdentifier: nil,
                       state: .failed("Upload failed – tap to retry")) {}
        AttachmentChip(name: "Map.png", size: 88_000, typeIdentifier: "public.png", state: .missing) {}
        AttachmentChip(name: "Statement.pdf", size: 310_000, typeIdentifier: "com.adobe.pdf",
                       state: .downloading(nil), onRemove: nil)
        AttachmentChip(name: "Boarding pass.pdf", size: 96_000, typeIdentifier: "com.adobe.pdf", state: .cached,
                       onRemove: nil)
    }
    .padding()
}

#Preview("Attachment strip") {
    AttachmentStrip(parts: ComponentSamples.parts, actions: SampleAttachmentActions())
        .frame(width: 640)
}

#Preview("Undo banner") {
    VStack(spacing: 16) {
        UndoSendBanner(subject: "Boat trip on Thursday", undoUntil: .now.addingTimeInterval(7)) {}
        UndoSendBanner(subject: "Boat trip on Thursday", undoUntil: .now.addingTimeInterval(7), isOffline: true,
                       onUndo: {}, onOpenOutbox: {})
    }
    .padding(40)
    .background(.background)
}

#Preview("Outbox pill") {
    VStack(spacing: 12) {
        OutboxPill(waiting: 1, failed: 0, pendingChanges: 2, isOffline: true) {}
        OutboxPill(waiting: 0, failed: 0, pendingChanges: 0, isOffline: true) {}
        OutboxPill(waiting: 2, failed: 1, pendingChanges: 0, isOffline: false) {}
    }
    .padding(40)
}

#Preview("Unsubscribe") {
    VStack(alignment: .leading, spacing: 16) {
        UnsubscribeControl(listName: "Fjord Outdoor", methods: ComponentSamples.oneClickMethods,
                           maskedAddress: "fjord.k3x9@fastmail.example", previousDate: nil,
                           mailtoNeedsIdentityConsent: false,
                           perform: { _ in "Unsubscribe requested – lists can take a few days" }, disableMask: {})
        UnsubscribeControl(listName: "Fjord Outdoor", methods: ComponentSamples.mailtoMethods,
                           maskedAddress: "fjord.k3x9@fastmail.example", previousDate: nil,
                           mailtoNeedsIdentityConsent: false, mailtoSenderMissing: true,
                           perform: { _ in nil }, disableMask: {})
        UnsubscribeControl(listName: "Weekly Digest", methods: ComponentSamples.webMethods, maskedAddress: nil,
                           previousDate: Date(timeIntervalSince1970: 1_791_500_000), mailtoNeedsIdentityConsent: false,
                           perform: { _ in nil }, disableMask: nil)
        UnsubscribeControl(listName: "Fjord Outdoor", methods: ComponentSamples.oneClickMethods,
                           maskedAddress: "fjord.k3x9@fastmail.example", isMaskDisabled: true, previousDate: nil,
                           mailtoNeedsIdentityConsent: false, perform: { _ in nil }, disableMask: {})
    }
    .padding()
    .frame(width: 560)
}

#Preview("Private web sheet") {
    PrivateWebSheet(url: ComponentSamples.unsubscribePage)
}
#endif
