import Foundation
import Combine

/// Keyless query-suggestion client for the launcher. Hits Google's public
/// Firefox-client suggest endpoint — no API key, no account — and parses the
/// classic array shape `["<query>", ["sug1","sug2",...], ...]`, where the
/// second element is the suggestion list.
///
/// It is deliberately defensive: a short debounce coalesces keystrokes, each
/// new request cancels the one in flight, the session times out fast, and
/// *every* failure (offline, timeout, cancel, malformed body) resolves to an
/// empty list. The palette therefore never blocks on, or is broken by, the
/// network — suggestions simply appear when (and if) they arrive.
@MainActor
final class SuggestClient: ObservableObject {
    /// Latest suggestions for the current query — deduped, stripped of an echo
    /// of the query itself, and capped. Empty whenever there's nothing to show.
    @Published private(set) var suggestions: [String] = []

    /// The query the published `suggestions` belong to. Lets a late response be
    /// dropped if the user has already typed past it.
    private(set) var activeQuery: String = ""

    private var task: Task<Void, Never>?
    private let session: URLSession
    private let maxResults = 4
    private let debounceMs: UInt64 = 150

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 3
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// Request suggestions for `text`. Cancels any in-flight/debouncing request.
    /// No-ops (and clears) for empty queries and anything that looks like a URL
    /// or address — those are served by direct-open / site prediction, not by
    /// search suggest.
    func request(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()

        guard !trimmed.isEmpty, !Self.looksLikeAddress(trimmed) else {
            clear()
            return
        }

        activeQuery = trimmed
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceMs * 1_000_000)
            if Task.isCancelled { return }
            let fetched = await self.fetch(trimmed)
            if Task.isCancelled { return }
            // Only publish if this is still the query the user cares about.
            guard self.activeQuery == trimmed else { return }
            self.suggestions = fetched
        }
    }

    /// Drop any pending request and clear results.
    func clear() {
        task?.cancel()
        activeQuery = ""
        if !suggestions.isEmpty { suggestions = [] }
    }

    private func fetch(_ q: String) async -> [String] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/#")
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string:
                "https://suggestqueries.google.com/complete/search?client=firefox&q=\(enc)")
        else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            return Self.parse(data, original: q, cap: maxResults)
        } catch {
            return []   // offline / timeout / cancelled → silent
        }
    }

    /// Parse `["q", ["s1","s2",...], ...]`. The suggestion list is the second
    /// element. Drops an exact echo of the query and caps the result.
    static func parse(_ data: Data, original: String, cap: Int) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let list = json[1] as? [String]
        else { return [] }

        let lowerOriginal = original.lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.lowercased() != lowerOriginal else { continue }
            guard seen.insert(s.lowercased()).inserted else { continue }
            out.append(s)
            if out.count >= cap { break }
        }
        return out
    }

    /// Heuristic: does this query look like an address rather than a phrase?
    /// A phrase (anything with a space) always wants suggestions; a bare token
    /// containing a scheme, a dot, or `localhost` is treated as an address.
    static func looksLikeAddress(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.contains("://") { return true }
        if text.lowercased().hasPrefix("localhost") { return true }
        if let dot = text.firstIndex(of: "."), dot != text.startIndex { return true }
        return false
    }
}
