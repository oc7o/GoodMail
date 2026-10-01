import Foundation

/// Strips click-tracking parameters from links before they are opened.
public enum LinkCleaner {
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "srsltid", "epik",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok",
        "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "_ke", "_kx", "ml_subscriber",
        "ml_subscriber_hash", "ck_subscriber_id", "dm_i", "s_cid", "sc_cid", "ef_id", "s_kwcid",
        "_openstat", "wickedid", "rb_clickid",
    ]
    static let trackingPrefixes = ["utm_", "pk_", "mtm_", "hsa_"]

    public static func isTrackingParameter(_ name: String) -> Bool {
        let name = name.lowercased()
        return trackingParameters.contains(name) || trackingPrefixes.contains { name.hasPrefix($0) }
    }

    /// Returns `url` without tracking parameters. Non-web URLs are returned unchanged.
    public static func clean(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems
        else { return url }

        let kept = items.filter { !isTrackingParameter($0.name.removingPercentEncoding ?? $0.name) }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }
}
