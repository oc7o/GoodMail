import MailPrivacy
import SwiftUI
import WebKit

/// Displays a rendered message without ever touching the network unless the policy allows images.
///
/// The view sizes itself to its content (reported through `height`) so the surrounding scroll view
/// does all the scrolling.
@MainActor
struct MessageWebView {
    let html: String
    let policy: RemoteContentPolicy
    @Binding var height: CGFloat
    /// Resolves a `cid:` reference to the image attached to the message.
    let inlineImage: @MainActor (String) async -> (data: Data, mimeType: String)?

    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if !WKWebView.handlesURLScheme(Coordinator.inlineImageScheme) {
            configuration.setURLSchemeHandler(coordinator, forURLScheme: Coordinator.inlineImageScheme)
        }
        // Our own script runs in an isolated world; the message's scripts never run at all.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Coordinator.sizeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
            in: .defaultClient))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "size")

        let webView = PlatformWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        #endif
        return webView
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        static let inlineImageScheme = "cid"

        /// Shrinks mail that is wider than the view, then reports the content height.
        static let sizeScript = """
            (() => {
                const body = document.body;
                const report = () => webkit.messageHandlers.size.postMessage(
                    Math.ceil(body.getBoundingClientRect().height));
                const fit = () => {
                    body.style.zoom = 1;
                    const overflow = document.documentElement.scrollWidth / window.innerWidth;
                    if (overflow > 1.01) body.style.zoom = 1 / overflow;
                    report();
                };
                new ResizeObserver(report).observe(body);
                window.addEventListener('resize', fit);
                window.addEventListener('load', fit);
                fit();
            })();
            """

        var parent: MessageWebView
        private var loaded: (html: String, policy: RemoteContentPolicy)?
        private var activeImageTasks: Set<ObjectIdentifier> = []

        init(parent: MessageWebView) {
            self.parent = parent
        }

        func load(into webView: WKWebView) {
            let html = parent.html
            let policy = parent.policy
            guard loaded?.html != html || loaded?.policy != policy else { return }
            loaded = (html, policy)
            Task {
                let rules = await RemoteContentRules.shared.ruleList(for: policy)
                guard self.loaded?.html == html, self.loaded?.policy == policy else { return }
                let controller = webView.configuration.userContentController
                controller.removeAllContentRuleLists()
                if let rules { controller.add(rules) }
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let height = message.body as? Double, height > 0, parent.height != height else { return }
            parent.height = height
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                    parent.openURL(LinkCleaner.clean(url))
                }
                return .cancel
            }
            // Only the document we load ourselves may occupy the frame.
            return action.request.url?.scheme == "about" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let id = ObjectIdentifier(task)
            activeImageTasks.insert(id)
            let url = task.request.url
            let cid = url.map { String($0.absoluteString.dropFirst(Self.inlineImageScheme.count + 1)) }
            Task {
                let image = await parent.inlineImage(cid?.removingPercentEncoding ?? "")
                guard activeImageTasks.remove(id) != nil else { return }
                guard let image, let url else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                task.didReceive(URLResponse(
                    url: url, mimeType: image.mimeType, expectedContentLength: image.data.count,
                    textEncodingName: nil))
                task.didReceive(image.data)
                task.didFinish()
            }
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
            activeImageTasks.remove(ObjectIdentifier(task))
        }
    }
}

#if os(macOS)
/// Hands scrolling to the enclosing scroll view instead of swallowing it.
private final class PlatformWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

extension MessageWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: webView)
    }
}
#else
private typealias PlatformWebView = WKWebView

extension MessageWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: webView)
    }
}
#endif

/// Compiles and caches the WebKit rule list for each remote content policy.
@MainActor
final class RemoteContentRules {
    static let shared = RemoteContentRules()

    private var cache: [RemoteContentPolicy: WKContentRuleList] = [:]

    func ruleList(for policy: RemoteContentPolicy) async -> WKContentRuleList? {
        if let cached = cache[policy] { return cached }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "remote-content-\(policy)", encodedContentRuleList: policy.contentRuleListJSON)
        cache[policy] = list
        return list
    }
}
