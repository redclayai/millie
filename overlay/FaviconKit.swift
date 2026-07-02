import SwiftUI
import AppKit
import CryptoKit

/// Persistent favicon store keyed by host. Chromium only hands Millie a decoded
/// favicon (`BrowserTab.faviconImage`) while a page is live, and that `NSImage`
/// is never persisted — so tabs restored from a previous session (or asleep
/// tabs that were never realized this run) have a `faviconURL` but no bitmap and
/// fall back to the globe. This cache closes that gap: every favicon Chromium
/// decodes is written to disk under its host, and the UI can rehydrate it (or,
/// on a cold cache, fetch the persisted favicon URL directly) without loading
/// the page. Fully local; the on-demand fetch is a plain image GET.
final class FaviconCache {
    static let shared = FaviconCache()

    private let memory = NSCache<NSString, NSImage>()
    private let io = DispatchQueue(label: "app.millie.faviconcache", qos: .utility)
    private var inFlight = Set<String>()      // hosts with a fetch running (main-actor guarded)

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent("MoriBrowser", isDirectory: true)
                    .appendingPathComponent("FaviconCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func fileURL(forHost host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8))
        let name = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name).appendingPathExtension("png")
    }

    /// Cached favicon for a host: memory first, then disk (promoted to memory).
    /// Synchronous and cheap; safe to call from a view body.
    func cached(host: String?) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        let key = host as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let url = fileURL(forHost: host)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: key)
        return image
    }

    /// Record a freshly-decoded favicon for a host (memory + disk).
    func store(_ image: NSImage, host: String?) {
        guard let host, !host.isEmpty else { return }
        memory.setObject(image, forKey: host as NSString)
        io.async { [weak self] in
            guard let self, let png = image.pngData() else { return }
            try? png.write(to: self.fileURL(forHost: host), options: .atomic)
        }
    }

    /// Resolve a favicon for display when there's no live bitmap: return the
    /// cached image, otherwise fetch the persisted favicon URL once, cache it,
    /// and return it. Returns nil only when there's nothing to show (→ globe).
    @MainActor
    func resolve(iconURL: String?, host: String?) async -> NSImage? {
        if let hit = cached(host: host) { return hit }
        guard let host, !host.isEmpty, !inFlight.contains(host),
              let iconURL, let url = URL(string: iconURL),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        inFlight.insert(host)
        defer { inFlight.remove(host) }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let image = NSImage(data: data) else { return nil }
            store(image, host: host)
            return image
        } catch {
            return nil
        }
    }
}

private extension NSImage {
    /// PNG encoding of the image at its natural pixel size, for the disk cache.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Favicon resolution for Millie. A curated brand glyph wins for known sites;
/// otherwise the UI shows the Chromium-decoded site favicon (supplied via
/// `BrowserTab.faviconImage`), falling back to a neutral web globe when a page
/// exposes no favicon at all. No host-derived letter tiles.
enum SiteBrand {
    static let map: [String: String] = [
        "github.com": "brand-github",
        "discord.com": "brand-discord",
        "discord.gg": "brand-discord",
        "notion.so": "brand-notion",
        "notion.com": "brand-notion",
        "slack.com": "brand-slack",
        "figma.com": "brand-figma",
        "trello.com": "brand-trello",
        "obsidian.md": "brand-obsidian",
        "tuta.com": "brand-tuta",
        "tutanota.com": "brand-tuta",
        "calendar.google.com": "brand-calendar",
    ]

    /// Curated brand asset for a page URL, if one exists for its host.
    static func asset(forPage page: String?) -> String? {
        guard let host = host(from: page) else { return nil }
        return asset(forHost: host)
    }

    /// Matches the host exactly or as a subdomain of a mapped registrable domain
    /// (so `gist.github.com` still resolves to GitHub).
    static func asset(forHost host: String) -> String? {
        if let exact = map[host] { return exact }
        for (domain, asset) in map where host.hasSuffix("." + domain) {
            return asset
        }
        return nil
    }

    /// Lowercased host without a leading `www.`; tolerates scheme-less input.
    static func host(from page: String?) -> String? {
        guard let page, !page.isEmpty else { return nil }
        let raw = URL(string: page)?.host
            ?? URL(string: "https://\(page)")?.host
        guard var h = raw?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }
}
