import Foundation

/// A curated, offline list of popular domains used to power launcher site
/// prediction: as you type a URL-ish query, Millie prefix-matches these and
/// offers them as "Open" results (e.g. "cn" → cnn.com, cnbc.com…), the way a
/// modern omnibox guesses a site before you've ever visited it. Deliberately
/// dependency-free and local — no network call, no Google suggest endpoint —
/// so predictions are instant and private. History (your real signal) always
/// ranks above these; they only fill the remaining slots.
///
/// Order = rough popularity; the matcher preserves it so the best-known site
/// for a prefix surfaces first.
enum TopDomains {
    /// Prefix-match `query` against the domain list. `query` may include a
    /// scheme and/or "www." — both are stripped. Matches when the registrable
    /// domain (or the full host) starts with the normalized token. Returns
    /// up to `limit` domains in popularity order.
    static func matches(for query: String, limit: Int = 6) -> [String] {
        var t = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A query with whitespace is a search, not a domain — don't predict.
        guard !t.isEmpty, !t.contains(" ") else { return [] }
        // Strip scheme + leading www.
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if t.hasPrefix("www.") { t = String(t.dropFirst(4)) }
        // Only the host portion matters for prediction (drop any path).
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        guard t.count >= 2 else { return [] }

        var out: [String] = []
        for domain in all {
            // Match against the full domain and against the registrable name
            // (the label before the first dot), so "cn" hits cnn.com and
            // "git" hits github.com.
            let name = domain.split(separator: ".").first.map(String.init) ?? domain
            if domain.hasPrefix(t) || name.hasPrefix(t) {
                out.append(domain)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// ~180 widely-used domains across search, social, dev, news, shopping,
    /// media, productivity, finance, and reference. Not exhaustive — a
    /// pragmatic head of the long tail that covers most "type a few letters"
    /// intents. Extend freely; order is popularity (earlier = more likely).
    static let all: [String] = [
        // Search / portals
        "google.com", "bing.com", "duckduckgo.com", "yahoo.com", "baidu.com",
        // Social / community
        "youtube.com", "facebook.com", "instagram.com", "x.com", "twitter.com",
        "reddit.com", "linkedin.com", "tiktok.com", "pinterest.com", "threads.net",
        "quora.com", "tumblr.com", "snapchat.com", "discord.com", "twitch.tv",
        // Dev / tech
        "github.com", "gitlab.com", "stackoverflow.com", "stackexchange.com",
        "npmjs.com", "developer.mozilla.org", "news.ycombinator.com", "vercel.com",
        "netlify.com", "cloudflare.com", "digitalocean.com", "heroku.com",
        "bitbucket.org", "codepen.io", "replit.com", "huggingface.co",
        // AI
        "openai.com", "chatgpt.com", "claude.ai", "anthropic.com", "gemini.google.com",
        "perplexity.ai", "midjourney.com",
        // Cloud / productivity
        "notion.so", "figma.com", "slack.com", "zoom.us", "dropbox.com",
        "drive.google.com", "docs.google.com", "sheets.google.com", "calendar.google.com",
        "gmail.com", "outlook.com", "office.com", "onedrive.live.com", "icloud.com",
        "trello.com", "asana.com", "atlassian.com", "linear.app", "airtable.com",
        "canva.com", "miro.com", "zapier.com", "clickup.com", "monday.com",
        // Shopping
        "amazon.com", "ebay.com", "etsy.com", "walmart.com", "target.com",
        "bestbuy.com", "aliexpress.com", "shopify.com", "costco.com", "wayfair.com",
        "homedepot.com", "ikea.com", "chewy.com",
        // News
        "cnn.com", "bbc.com", "nytimes.com", "washingtonpost.com", "theguardian.com",
        "reuters.com", "apnews.com", "bloomberg.com", "cnbc.com", "wsj.com",
        "foxnews.com", "nbcnews.com", "npr.org", "forbes.com", "businessinsider.com",
        "theverge.com", "techcrunch.com", "arstechnica.com", "wired.com", "engadget.com",
        // Media / streaming
        "netflix.com", "hulu.com", "disneyplus.com", "hbomax.com", "max.com",
        "spotify.com", "soundcloud.com", "primevideo.com", "paramountplus.com",
        "peacocktv.com", "apple.com", "music.apple.com", "tv.apple.com",
        // Reference / education
        "wikipedia.org", "wiktionary.org", "archive.org", "imdb.com", "goodreads.com",
        "coursera.org", "udemy.com", "khanacademy.org", "edx.org", "duolingo.com",
        "medium.com", "substack.com", "dictionary.com", "britannica.com",
        // Finance
        "paypal.com", "chase.com", "bankofamerica.com", "wellsfargo.com", "coinbase.com",
        "robinhood.com", "fidelity.com", "schwab.com", "venmo.com", "mint.com",
        // Travel / maps / local
        "maps.google.com", "booking.com", "airbnb.com", "expedia.com", "tripadvisor.com",
        "uber.com", "lyft.com", "yelp.com", "doordash.com", "ubereats.com",
        // Google properties / misc
        "translate.google.com", "photos.google.com", "play.google.com", "meet.google.com",
        "microsoft.com", "adobe.com", "salesforce.com", "oracle.com", "ibm.com",
        "wordpress.com", "wix.com", "squarespace.com", "godaddy.com", "namecheap.com",
    ]
}
