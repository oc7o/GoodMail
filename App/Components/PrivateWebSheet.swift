import SwiftUI
import WebKit

/// A mailing list's unsubscribe page in a private window.
///
/// The page gets a non-persistent website data store, so nothing it stores (cookies, local storage, cache) outlives
/// the sheet, and nothing stored elsewhere reaches it. JavaScript stays on because unsubscribe forms need it; the
/// page has no bridge into the app, and navigation is limited to web schemes, so a page can't open other apps.
/// "Open in Safari" is the way out when a page doesn't work here.
struct PrivateWebSheet: View {
    private let url: URL

    @State private var page: WebPage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(url: URL) {
        self.url = url
    }

    var body: some View {
        NavigationStack {
            Group {
                if let page {
                    WebView(page)
                } else {
                    Color.clear
                }
            }
            .overlay(alignment: .top) {
                if let page, page.isLoading {
                    ProgressView(value: page.estimatedProgress)
                        .progressViewStyle(.linear)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { safariButton }
                ToolbarItem(placement: .confirmationAction) { doneButton }
            }
            #endif
        }
        #if os(macOS)
        // A Mac sheet shows only confirmation and cancellation toolbar items, so both buttons get a bar of their own.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                safariButton
                Spacer()
                doneButton.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 480, idealHeight: 680)
        #endif
        .task {
            guard page == nil else { return }
            let page = Self.makePage()
            self.page = page
            page.load(url)
        }
    }

    private var doneButton: some View {
        Button("Done") { dismiss() }
    }

    private var safariButton: some View {
        Button("Open in Safari", systemImage: "safari") {
            openURL(page?.url ?? url)
        }
        .help("Open this page in your browser")
    }

    private var title: String {
        if let title = page?.title, !title.isEmpty { return title }
        return (page?.url ?? url).host() ?? "Unsubscribe"
    }

    static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.upgradeKnownHostsToHTTPS = true
        return WebPage(configuration: configuration, navigationDecider: PrivateWebNavigation())
    }
}

/// Web pages may navigate to web pages only: a custom scheme or a `file:` link would leave the private window.
private struct PrivateWebNavigation: WebPage.NavigationDeciding {
    static let allowedSchemes: Set<String> = ["https", "http", "about", "blob", "data"]

    func decidePolicy(
        for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let scheme = action.request.url?.scheme?.lowercased() else { return .cancel }
        return Self.allowedSchemes.contains(scheme) ? .allow : .cancel
    }
}
