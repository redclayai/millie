import Foundation

/// Strips tracking / analytics query parameters from a URL for "Super Copy"
/// (Arc parity): copy a clean, shareable link with no `utm_*`, click IDs, or
/// share-attribution junk. Deliberately conservative — it only removes a
/// known-tracking allowlist (plus any `utm_*` / `pk_*` prefix and a few
/// host-scoped share tokens), never functional query params, so a copied link
/// still works.
enum URLCleaner {
    /// Exact query-parameter names removed on any host (compared lowercased).
    private static let alwaysStrip: Set<String> = [
        // Google / Ads
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad",
        "_ga", "_gl", "gi", "srsltid",
        // Social / referrers
        "fbclid", "mc_eid", "mc_cid", "igshid", "igsh", "twclid",
        "yclid", "li_fat_id", "epik", "ttclid", "rdt_cid", "guccounter",
        "guce_referrer", "guce_referrer_sig",
        // Microsoft / Bing
        "msclkid",
        // Email / marketing platforms
        "mkt_tok", "_hsenc", "_hsmi", "hsctatracking", "__hssc", "__hstc",
        "__hsfp", "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id",
        "ml_subscriber", "ml_subscriber_hash", "wickedid", "_openstat",
        "s_cid", "cmpid", "scid", "ck_subscriber_id", "redirect_log_mongo_id",
        "redirect_mongo_id", "sb_referer_host", "_branch_match_id",
        // Misc
        "ref_src", "ref_url", "spm", "wt_mc", "wt_zmc", "trk_contact",
    ]

    /// Prefix matches removed on any host (e.g. all `utm_*`, Matomo `pk_*`).
    private static let strippedPrefixes: [String] = ["utm_", "pk_", "piwik_", "matomo_"]

    /// Share tokens that are only tracking on specific hosts (too generic to
    /// strip globally — e.g. `si`/`s`/`t` are meaningful params elsewhere).
    private static let hostScoped: [(suffix: String, params: Set<String>)] = [
        ("youtube.com", ["si", "feature", "pp", "ab_channel"]),
        ("youtu.be", ["si", "feature"]),
        ("open.spotify.com", ["si", "nd", "context"]),
        ("x.com", ["s", "t", "ref_src", "ref_url"]),
        ("twitter.com", ["s", "t", "ref_src", "ref_url"]),
    ]

    /// Returns `raw` with tracking parameters removed. Leaves the URL untouched
    /// if it has no query, can't be parsed, or nothing matches.
    static func clean(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw),
              let items = comps.queryItems, !items.isEmpty else {
            return raw
        }
        let host = (comps.host ?? "").lowercased()
        let hostKeys: Set<String> = hostScoped
            .first { host == $0.suffix || host.hasSuffix("." + $0.suffix) }?
            .params ?? []

        let kept = items.filter { item in
            let name = item.name.lowercased()
            if alwaysStrip.contains(name) { return false }
            if strippedPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            if hostKeys.contains(name) { return false }
            return true
        }
        guard kept.count != items.count else { return raw }  // nothing stripped
        comps.queryItems = kept.isEmpty ? nil : kept
        // Avoid leaving a dangling "?" when every param was tracking.
        if comps.queryItems == nil { comps.percentEncodedQuery = nil }
        return comps.string ?? raw
    }
}
