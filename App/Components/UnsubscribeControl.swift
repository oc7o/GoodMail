import MailPrivacy
import SwiftUI

/// The mailing-list row of the reading pane's privacy bar (content, no glass): "Mailing list · Fjord Outdoor" with a
/// small Unsubscribe button, and below it what happened last ("Unsubscribe requested on 9 Oct").
///
/// The button asks first, in a dialog anchored at it and worded for the way the list offers (D26, in the order
/// `methods` gives): one-click asks the list's server straight from this device and says that the list sees the
/// IP address; mailto names the message and the sender; a web-only list opens in a `PrivateWebSheet`. Mail to a
/// masked address also offers to disable that address instead. When the mailto sender is a masked address without
/// a sending identity, the dialog either asks for consent to create one (`mailtoNeedsIdentityConsent`) or, when
/// GoodMail may not create identities (`mailtoSenderMissing`), explains how to add it in Fastmail and offers the
/// other ways. After an attempt, the dialog also lists the list's other ways, in case the first didn't work.
struct UnsubscribeControl: View {
    private let listName: String
    private let methods: [ListUnsubscribe.Method]
    private let maskedAddress: String?
    private let previousDate: Date?
    private let mailtoNeedsIdentityConsent: Bool
    private let mailtoSenderMissing: Bool
    private let perform: (ListUnsubscribe.Method) async -> String?
    private let disableMask: (() async -> Void)?

    @State private var isConfirming = false
    @State private var isWorking = false
    @State private var hasAttempted = false
    @State private var status: String?
    @State private var page: UnsubscribePage?

    init(
        listName: String, methods: [ListUnsubscribe.Method], maskedAddress: String?, previousDate: Date?,
        mailtoNeedsIdentityConsent: Bool, mailtoSenderMissing: Bool = false,
        perform: @escaping (ListUnsubscribe.Method) async -> String?, disableMask: (() async -> Void)?
    ) {
        self.listName = listName
        self.methods = methods
        self.maskedAddress = maskedAddress
        self.previousDate = previousDate
        self.mailtoNeedsIdentityConsent = mailtoNeedsIdentityConsent
        self.mailtoSenderMissing = mailtoSenderMissing
        self.perform = perform
        self.disableMask = disableMask
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mailing list · \(listName)")
                        .lineLimit(1)
                    if let statusLine {
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "list.bullet.rectangle")
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if canOfferSomething {
                Button("Unsubscribe") { isConfirming = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isWorking)
                    .accessibilityHint("Asks before anything is sent")
                    .confirmationDialog("Unsubscribe from \(listName)?", isPresented: $isConfirming,
                                        titleVisibility: .visible) {
                        dialogActions
                    } message: {
                        Text(dialogMessage)
                    }
            }
        }
        .font(.subheadline)
        .sheet(item: $page) { page in
            PrivateWebSheet(url: page.url)
        }
    }

    // MARK: Dialog

    @ViewBuilder private var dialogActions: some View {
        if let primary {
            Button(title(for: primary, isPrimary: true)) { run(primary) }
        }
        if hasAttempted {
            ForEach(alternatives, id: \.self) { method in
                Button(title(for: method, isPrimary: false)) { run(method) }
            }
        }
        if let maskedAddress, disableMask != nil {
            Button("Disable Masked Address Instead") { disable(maskedAddress) }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var dialogMessage: String {
        let address = maskedAddress ?? "your address"
        guard let primary else {
            return mailtoSenderMissingText
        }
        switch primary {
        case .oneClick(let url):
            return "GoodMail will ask \(url.host() ?? "the list") to remove \(address). The request comes straight "
                + "from this device, so the list can see your IP address. No browser or cookies are involved."
        case .mailto(let link):
            if mailtoNeedsIdentityConsent, let maskedAddress {
                return "Fastmail needs a sending identity for \(maskedAddress) to send the unsubscribe email. "
                    + "GoodMail can create it; it then appears in Fastmail under Settings → My email addresses, "
                    + "where you can delete it."
            }
            var text = "GoodMail will email \(link.to.joined(separator: ", ")) from \(address)"
            if let subject = link.subject, !subject.isEmpty { text += " with the subject “\(subject)”" }
            text += "."
            if let body = link.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                text += "\n\n" + (body.count > 400 ? String(body.prefix(400)) + "…" : body)
            }
            return text
        case .web:
            return "This list only lets you unsubscribe on its website. GoodMail opens it in a private window "
                + "that keeps no cookies, but the site will see your IP address."
        }
    }

    private var mailtoSenderMissingText: String {
        let address = maskedAddress ?? "this address"
        return "Fastmail only lets apps send from a masked address that is a sending address. To unsubscribe by "
            + "email, add \(address) in Fastmail under Settings → My email addresses."
    }

    private func title(for method: ListUnsubscribe.Method, isPrimary: Bool) -> String {
        switch method {
        case .oneClick: isPrimary ? "Unsubscribe" : "Ask the List Again"
        case .mailto: isPrimary
            ? (mailtoNeedsIdentityConsent ? "Create and Send" : "Send Unsubscribe Email")
            : "Send Unsubscribe Email Instead"
        case .web: isPrimary ? "Open Unsubscribe Page" : "Open Unsubscribe Page Instead"
        }
    }

    // MARK: Methods

    /// The first way the list offers that can be carried out; mailto is skipped when its sender can't send.
    private var primary: ListUnsubscribe.Method? {
        usableMethods.first
    }

    private var alternatives: [ListUnsubscribe.Method] {
        Array(usableMethods.dropFirst())
    }

    private var usableMethods: [ListUnsubscribe.Method] {
        methods.filter { method in
            if case .mailto = method { return !mailtoSenderMissing }
            return true
        }
    }

    private var canOfferSomething: Bool {
        primary != nil || (maskedAddress != nil && disableMask != nil)
    }

    private var statusLine: String? {
        if let status { return status }
        return previousDate.map { "Unsubscribe requested on \($0.formatted(.dateTime.day().month(.abbreviated)))" }
    }

    private func run(_ method: ListUnsubscribe.Method) {
        if case .web(let url) = method { page = UnsubscribePage(url: url) }
        isWorking = true
        Task {
            let result = await perform(method)
            isWorking = false
            hasAttempted = true
            if let result { status = result }
        }
    }

    private func disable(_ address: String) {
        guard let disableMask else { return }
        isWorking = true
        Task {
            await disableMask()
            isWorking = false
            status = "\(address) is disabled; its mail now goes to Trash."
        }
    }
}

private struct UnsubscribePage: Identifiable {
    let url: URL
    var id: URL { url }
}
