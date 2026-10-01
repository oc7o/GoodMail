import Foundation

extension RemoteContentPolicy {
    /// A WebKit content rule list enforcing this policy at the network layer, as a second line of
    /// defence behind the document's Content-Security-Policy.
    public var contentRuleListJSON: String {
        func rule(_ filter: String, _ action: String, resourceTypes: [String]? = nil) -> [String: Any] {
            var trigger: [String: Any] = ["url-filter": filter]
            trigger["resource-type"] = resourceTypes
            return ["trigger": trigger, "action": ["type": action]]
        }

        // Later rules win, so trackers stay blocked after images are let through.
        var rules = ["^https?:", "^wss?:", "^ftp:"].map { rule($0, "block") }
        if self == .allowImages {
            rules.append(rule("^https:", "ignore-previous-rules", resourceTypes: ["image"]))
            rules += TrackerList.contentRuleFilters.map { rule($0, "block") }
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
