import Foundation

/// Endpoints of common email open-tracking services.
///
/// This only matters once the user opts in to remote images; until then nothing remote loads at all.
public enum TrackerList {
    struct Entry: Sendable {
        /// Matches the host itself and any subdomain.
        let host: String
        /// If set, the URL path must contain this.
        let path: String?
    }

    static let entries: [Entry] = [
        Entry(host: "list-manage.com", path: "/track/open"),
        Entry(host: "mandrillapp.com", path: "/track/open"),
        Entry(host: "sendgrid.net", path: "/wf/open"),
        Entry(host: "exct.net", path: "/open.aspx"),
        Entry(host: "hubspot.com", path: "/__ptq.gif"),
        Entry(host: "pstmrk.it", path: "/open"),
        Entry(host: "awstrack.me", path: nil),
        Entry(host: "mailtrack.io", path: nil),
        Entry(host: "t.yesware.com", path: nil),
        Entry(host: "r.superhuman.com", path: nil),
        Entry(host: "mailfoogae.appspot.com", path: nil),
        Entry(host: "bananatag.com", path: nil),
        Entry(host: "getnotify.com", path: nil),
        Entry(host: "google-analytics.com", path: nil),
        Entry(host: "doubleclick.net", path: nil),
    ]

    public static func isTracker(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        return entries.contains { entry in
            (host == entry.host || host.hasSuffix("." + entry.host)) && (entry.path.map(path.contains) ?? true)
        }
    }

    /// One `url-filter` regular expression per entry, in WebKit content rule list syntax.
    public static var contentRuleFilters: [String] {
        entries.map { entry in
            let host = "^https?://([^/]*\\.)?" + NSRegularExpression.escapedPattern(for: entry.host)
            guard let path = entry.path else { return host + "[:/]" }
            return host + "(:[0-9]*)?(/.*)?" + NSRegularExpression.escapedPattern(for: path)
        }
    }
}
