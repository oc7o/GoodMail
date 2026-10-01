import GoodMailCore
import JMAPKit
import SwiftUI

/// The signed-in app: mailboxes, the list for the selected one, and the reading pane.
struct MailView: View {
    @Bindable var model: MailModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            switch model.destination {
            case .maskedEmail:
                MaskedEmailListView(model: model)
            default:
                ThreadListView(model: model)
            }
        } detail: {
            switch model.destination {
            case .maskedEmail:
                if let id = model.selectedMaskedEmailID, let masked = model.maskedEmails.first(where: { $0.id == id }) {
                    MaskedEmailDetailView(model: model, masked: masked)
                        .id(id)
                } else {
                    ContentUnavailableView("No Address Selected", systemImage: "theatermasks")
                }
            default:
                if let id = model.selectedThreadID {
                    ThreadView(model: model, threadID: id)
                        .id(id)
                } else {
                    ContentUnavailableView("No Conversation Selected", systemImage: "envelope.open")
                }
            }
        }
        .task { await model.start() }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
