import Foundation
import SwiftUI

// MARK: - Model

/// Where a live folder pulls its links from. Codable so it rides along in
/// `TabFolder` through session save/restore (Arc "Live folders" parity).
struct LiveFolderSource: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case rss            // RSS or Atom feed
        case githubPRs      // a repo's open pull requests
        case githubIssues   // a repo's open issues
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rss: return "RSS / Atom feed"
            case .githubPRs: return "GitHub pull requests"
            case .githubIssues: return "GitHub issues"
            }
        }
        var placeholder: String {
            switch self {
            case .rss: return "https://example.com/feed.xml"
            case .githubPRs, .githubIssues: return "owner/repo"
            }
        }
        var symbol: String {
            switch self {
            case .rss: return "dot.radiowaves.up.forward"
            case .githubPRs: return "arrow.triangle.pull"
            case .githubIssues: return "smallcircle.filled.circle"
            }
        }
    }

    var kind: Kind
    /// Feed URL (`rss`) or `owner/repo` (GitHub kinds).
    var target: String
    /// Max items shown. Clamped 1…50.
    var limit: Int

    init(kind: Kind, target: String, limit: Int = 20) {
        self.kind = kind
        self.target = target
        self.limit = min(max(limit, 1), 50)
    }

    private enum CodingKeys: String, CodingKey { case kind, target, limit }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        target = try c.decode(String.self, forKey: .target)
        limit = (try c.decodeIfPresent(Int.self, forKey: .limit)) ?? 20
    }
}

/// One fetched link in a live folder. Ephemeral — never persisted; refreshed
/// from the source.
struct LiveFolderItem: Identifiable, Equatable {
    var id: String { url }
    let title: String
    let url: String
    let subtitle: String?   // date / author / #number, shown dimmed under the title
}

struct LiveFolderError: Error { let message: String }

// MARK: - Store

/// Polls each live folder's source on an interval and publishes its current
/// items for the sidebar. Independent of the tab model: live items are links,
/// not open tabs, so they don't touch `TabFolder.tabIDs`.
final class LiveFolderStore: ObservableObject {
    static let shared = LiveFolderStore()

    @Published private(set) var items: [UUID: [LiveFolderItem]] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var lastUpdated: [UUID: Date] = [:]
    @Published private(set) var errors: [UUID: String] = [:]

    private var timer: Timer?
    private var foldersProvider: (() -> [TabFolder])?
    private static let pollInterval: TimeInterval = 900  // 15 min

    /// Begin periodic refresh (plus one immediate pass). `provider` returns the
    /// current set of folders across all Spaces so background Spaces stay fresh.
    /// Idempotent; updates the provider each call.
    func start(provider: @escaping () -> [TabFolder]) {
        foldersProvider = provider
        if timer == nil {
            // Reference the singleton rather than capturing self so the (Sendable)
            // timer block holds nothing non-Sendable.
            let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
                LiveFolderStore.shared.refreshAll()
            }
            t.tolerance = 60
            timer = t
        }
        refreshAll()
    }

    func refreshAll() {
        for folder in (foldersProvider?() ?? []) where folder.liveSource != nil {
            refresh(folder)
        }
    }

    /// Fetch one folder's source. No-op if it isn't live or a refresh is already
    /// in flight for it.
    func refresh(_ folder: TabFolder) {
        guard let source = folder.liveSource, !refreshing.contains(folder.id) else { return }
        let id = folder.id
        refreshing.insert(id)
        // Capture only Sendable values (source, id); deliver results back on the
        // main actor via the singleton — no non-Sendable self in the Task.
        Task {
            do {
                let fetched = try await Self.fetch(source)
                await MainActor.run { LiveFolderStore.shared.apply(id: id, items: fetched, error: nil) }
            } catch {
                let msg = (error as? LiveFolderError)?.message ?? "Couldn't refresh"
                await MainActor.run { LiveFolderStore.shared.apply(id: id, items: nil, error: msg) }
            }
        }
    }

    @MainActor private func apply(id: UUID, items newItems: [LiveFolderItem]?, error: String?) {
        if let newItems { items[id] = newItems; lastUpdated[id] = Date() }
        errors[id] = error
        refreshing.remove(id)
    }

    /// Drop cached state for a removed folder.
    func forget(_ id: UUID) {
        items[id] = nil; lastUpdated[id] = nil; errors[id] = nil; refreshing.remove(id)
    }

    // MARK: Fetch (off-main; nonisolated)

    private static func fetch(_ source: LiveFolderSource) async throws -> [LiveFolderItem] {
        switch source.kind {
        case .rss:          return try await fetchRSS(source.target)
        case .githubPRs:    return try await fetchGitHub(repo: source.target, pulls: true)
        case .githubIssues: return try await fetchGitHub(repo: source.target, pulls: false)
        }
    }

    private static func request(_ url: URL, accept: String? = nil) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        // Generic client identifier — never the user's email (GitHub requires a UA).
        r.setValue("Millie", forHTTPHeaderField: "User-Agent")
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        return r
    }

    private static func load(_ url: URL, accept: String? = nil) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, accept: accept))
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw LiveFolderError(message: "Source returned HTTP \(http.statusCode)")
            }
            return data
        } catch let e as LiveFolderError {
            throw e
        } catch {
            throw LiveFolderError(message: "Network error")
        }
    }

    // MARK: RSS / Atom

    private static func fetchRSS(_ target: String) async throws -> [LiveFolderItem] {
        guard let url = URL(string: target.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            throw LiveFolderError(message: "Enter a full feed URL")
        }
        let data = try await load(url, accept: "application/rss+xml, application/atom+xml, application/xml, text/xml")
        let parser = RSSFeedParser()
        guard parser.parse(data) else { throw LiveFolderError(message: "Couldn't read this feed") }
        if parser.items.isEmpty { throw LiveFolderError(message: "No entries in this feed") }
        return parser.items
    }

    // MARK: GitHub

    private static func fetchGitHub(repo: String, pulls: Bool) async throws -> [LiveFolderItem] {
        let slug = repo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://github.com/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = slug.split(separator: "/")
        guard parts.count == 2 else { throw LiveFolderError(message: "Use owner/repo") }
        let endpoint = pulls ? "pulls" : "issues"
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/\(endpoint)?state=open&per_page=50&sort=updated") else {
            throw LiveFolderError(message: "Use owner/repo")
        }
        let data = try await load(url, accept: "application/vnd.github+json")
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LiveFolderError(message: "Couldn't read GitHub response")
        }
        let fmtIn = ISO8601DateFormatter()
        var out: [LiveFolderItem] = []
        for obj in arr {
            // The issues endpoint also returns PRs; skip them for a pure issue list.
            if !pulls, obj["pull_request"] != nil { continue }
            guard let title = obj["title"] as? String,
                  let link = obj["html_url"] as? String else { continue }
            let number = (obj["number"] as? Int).map { "#\($0)" } ?? ""
            let user = ((obj["user"] as? [String: Any])?["login"] as? String).map { "@\($0)" } ?? ""
            var when = ""
            if let updated = obj["updated_at"] as? String, let d = fmtIn.date(from: updated) {
                when = relativeDate(d)
            }
            let subtitle = [number, user, when].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(LiveFolderItem(title: title, url: link, subtitle: subtitle.isEmpty ? nil : subtitle))
        }
        if out.isEmpty { throw LiveFolderError(message: pulls ? "No open pull requests" : "No open issues") }
        return out
    }

    private static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - RSS / Atom parser

/// Minimal RSS 2.0 + Atom parser: pulls <item>/<entry> title + link (+ date).
private final class RSSFeedParser: NSObject, XMLParserDelegate {
    private(set) var items: [LiveFolderItem] = []

    private var inItem = false
    private var current = ""          // text accumulator
    private var title = ""
    private var link = ""
    private var date = ""
    private var element = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        element = name.lowercased()
        current = ""
        switch element {
        case "item", "entry":
            inItem = true; title = ""; link = ""; date = ""
        case "link" where inItem:
            // Atom carries the URL in an href attribute; prefer the alternate.
            if let href = attrs["href"], !href.isEmpty {
                if link.isEmpty || attrs["rel"] == "alternate" || attrs["rel"] == nil { link = href }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { current += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let el = name.lowercased()
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "title" where inItem:
            if title.isEmpty { title = text }
        case "link" where inItem:
            if link.isEmpty, !text.isEmpty { link = text }   // RSS text-node link
        case "pubdate", "published", "updated", "dc:date":
            if inItem, date.isEmpty { date = text }
        case "item", "entry":
            if !title.isEmpty, !link.isEmpty {
                items.append(LiveFolderItem(title: title, url: link,
                                            subtitle: date.isEmpty ? nil : date))
            }
            inItem = false
        default:
            break
        }
        current = ""
    }
}
