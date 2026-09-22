import SwiftUI

@main
struct GoodMailApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.restore() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .signedOut:
            OnboardingView()
        case .signedIn(let client):
            MailboxListView(client: client)
        }
    }
}
