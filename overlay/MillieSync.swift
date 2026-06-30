import Foundation
import Combine

/// Cross-device sync for Millie desktop ⇄ the Milly iOS companion, over the same
/// Supabase project the iOS app uses (`millie_*` tables, RLS-scoped per user).
///
/// Deliberately dependency-free: a thin URLSession REST client (GoTrue auth +
/// PostgREST), so it drops into the gn swift_source_set without vendoring the
/// supabase-swift SPM. Mirrors the iOS `SupabaseSyncClient` row shapes.
///
/// v1 scope: PUSH the full local snapshot (tabs, Spaces, profiles, bookmarks,
/// history, archive) so the phone sees the desktop; PULL + merge the library
/// (bookmarks/history/archive); and consume `millie_commands` (open-tab-on-Mac).
/// Structural two-way tab/Space merge into the live browser is intentionally not
/// done yet (would mutate a running Chromium session).
@MainActor
final class MillieSync: ObservableObject {
    static let shared = MillieSync()

    // UI-facing state.
    @Published private(set) var isSignedIn = false
    @Published private(set) var email: String?
    @Published var codeSent = false
    @Published var statusMessage: String?

    // Config — same project as the iOS app.
    private let baseURL = URL(string: "https://tyvqnxqlwghndtymjazm.supabase.co")!
    private let anonKey = "sb_publishable_uZXk6eovZ5SWzTKb46oP6w_I7WEp7-W"

    // Session tokens. The refresh token is long-lived and grants new access
    // tokens, so it lives in the Keychain — not UserDefaults, which is a
    // world-readable plist. The short-lived access token stays in memory only.
    private var accessToken: String?
    private var refreshToken: String? {
        didSet {
            if let refreshToken { Keychain.set(refreshToken, for: K.refreshAccount) }
            else { Keychain.delete(K.refreshAccount) }
        }
    }
    private var pendingEmail: String?

    private weak var browser: BrowserStore?
    private var bag = Set<AnyCancellable>()
    private var pushItem: DispatchWorkItem?
    private var pollTask: Task<Void, Never>?
    /// True while a remote pull is being merged in, so the resulting local
    /// mutations don't bounce straight back out as a push.
    private var applyingRemote = false

    private let defaults = UserDefaults.standard
    private enum K {
        static let refresh = "mori.sync.refreshToken"   // legacy UserDefaults key (migrated out)
        static let refreshAccount = "millie.sync.refreshToken"  // Keychain account
        static let email = "mori.sync.email"
    }

    private init() {}

    // MARK: Attach

    /// Called once after the stores exist. Restores a session, starts observing
    /// local changes (to push) and remote changes (to pull).
    func attach(browser: BrowserStore) {
        self.browser = browser
        // One-time migration: move any plaintext refresh token out of
        // UserDefaults into the Keychain, then scrub the legacy key.
        if Keychain.get(K.refreshAccount) == nil, let legacy = defaults.string(forKey: K.refresh) {
            Keychain.set(legacy, for: K.refreshAccount)
            defaults.removeObject(forKey: K.refresh)
        }
        refreshToken = Keychain.get(K.refreshAccount)
        email = defaults.string(forKey: K.email)

        // Push on any local change to the synced stores.
        browser.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)
        BookmarkStore.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)
        HistoryStore.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)
        ArchiveStore.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)

        if refreshToken != nil {
            Task { await refreshSession(); if accessToken != nil { isSignedIn = true; await startSyncing() } }
        }
    }

    // MARK: Auth (email OTP)

    func sendCode(email: String) async {
        pendingEmail = email
        do {
            try await post("/auth/v1/otp", body: ["email": email, "create_user": true], authed: false)
            codeSent = true
            statusMessage = "Code sent to \(email)"
        } catch {
            statusMessage = "Couldn't send code"
        }
    }

    func verify(code: String) async {
        guard let pendingEmail else { return }
        do {
            let data = try await postData("/auth/v1/verify",
                                          body: ["type": "email", "email": pendingEmail, "token": code],
                                          authed: false)
            let session = try JSONDecoder().decode(AuthSession.self, from: data)
            applySession(session)
            codeSent = false
            statusMessage = nil
            await startSyncing()
        } catch {
            statusMessage = "Invalid code"
        }
    }

    func signOut() {
        accessToken = nil; refreshToken = nil; email = nil; pendingEmail = nil
        defaults.removeObject(forKey: K.email)
        isSignedIn = false; codeSent = false
        pollTask?.cancel(); pollTask = nil
    }

    private func applySession(_ s: AuthSession) {
        accessToken = s.access_token
        refreshToken = s.refresh_token
        email = s.user?.email
        defaults.set(email, forKey: K.email)
        isSignedIn = true
    }

    private func refreshSession() async {
        guard let token = refreshToken else { return }
        do {
            let data = try await postData("/auth/v1/token?grant_type=refresh_token",
                                          body: ["refresh_token": token], authed: false)
            let s = try JSONDecoder().decode(AuthSession.self, from: data)
            applySession(s)
        } catch {
            // refresh failed — drop the session quietly
            accessToken = nil
        }
    }

    // MARK: Sync lifecycle

    private func startSyncing() async {
        await pushNow()
        await pull()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.isSignedIn else { continue }
                await self.pull()
            }
        }
    }

    func schedulePush() {
        guard isSignedIn, !applyingRemote else { return }
        pushItem?.cancel()
        let item = DispatchWorkItem { [weak self] in Task { await self?.pushNow() } }
        pushItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func pushNow() async {
        guard isSignedIn, let browser else { return }
        // Private (incognito) Spaces and their tabs are never synced.
        let publicContexts = browser.contexts.filter { !$0.isPrivate }
        let privateTabIDs = Set(browser.contexts.filter(\.isPrivate)
            .flatMap { $0.tabIDs + $0.pinnedTabIDs + $0.folders.flatMap(\.tabIDs) })
        // Build row arrays from current local state.
        var spaceForTab: [UUID: UUID] = [:]
        for c in publicContexts {
            for id in c.tabIDs + c.pinnedTabIDs + c.folders.flatMap(\.tabIDs) { spaceForTab[id] = c.id }
        }
        let profiles = browser.profiles.map(ProfileRow.init)
        let spaces = publicContexts.enumerated().map { SpaceRow($0.element, order: $0.offset) }
        let tabs = persistedTabRows(spaceForTab: spaceForTab)
            .filter { !privateTabIDs.contains($0.id) }
        let bookmarks = BookmarkStore.shared.bookmarks.map(BookmarkRow.init)
        let history = HistoryStore.shared.entries.map(HistoryRow.init)
        let archive = ArchiveStore.shared.tabs.map(ArchiveRow.init)
        NSLog("MILLIE_SYNC push profiles=%d spaces=%d tabs=%d", profiles.count, spaces.count, tabs.count)

        await upsert("millie_profiles", profiles)
        await upsert("millie_spaces", spaces)
        await upsert("millie_tabs", tabs)
        await upsert("millie_bookmarks", bookmarks)
        await upsert("millie_history", history)
        await upsert("millie_archive", archive)

        // Propagate local deletions as tombstones (deleted=true) so other devices
        // drop them instead of resurrecting them on the next union merge.
        let (deadTabs, deadSpaces) = browser.drainTombstones()
        for id in deadTabs { try? await patch("millie_tabs", id: id, body: ["deleted": true]) }
        for id in deadSpaces { try? await patch("millie_spaces", id: id, body: ["deleted": true]) }
    }

    /// Tabs for ALL Spaces — sourced from the persisted session (`session.json`),
    /// not just `browser.tabs`, which only holds the realized tabs of the active
    /// Space. Falls back to the realized tabs if the file can't be read.
    private func persistedTabRows(spaceForTab: [UUID: UUID]) -> [TabSyncRow] {
        let file = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoriBrowser/session.json")
        if let data = try? Data(contentsOf: file),
           let session = try? JSONDecoder().decode(SessionFile.self, from: data),
           !session.tabs.isEmpty {
            return session.tabs.map { TabSyncRow($0, spaceID: spaceForTab[$0.id]) }
        }
        return (browser?.tabs ?? []).map { TabSyncRow($0, spaceID: spaceForTab[$0.id]) }
    }

    private func pull() async {
        guard isSignedIn else { return }
        // Library merge (safe, additive).
        if let rows: [BookmarkRow] = try? await select("millie_bookmarks") {
            let local = Set(BookmarkStore.shared.bookmarks.map(\.url))
            for r in rows where !local.contains(r.url) {
                _ = BookmarkStore.shared.toggle(url: r.url, title: r.title)
            }
        }
        if let rows: [HistoryRow] = try? await select("millie_history") {
            let local = Set(HistoryStore.shared.entries.map(\.url))
            for r in rows where !local.contains(r.url) {
                HistoryStore.shared.record(url: r.url, title: r.title)
            }
        }
        if let rows: [ArchiveRow] = try? await select("millie_archive") {
            let local = Set(ArchiveStore.shared.tabs.map(\.url))
            for r in rows where !local.contains(r.url) {
                ArchiveStore.shared.add(url: r.url, title: r.title, faviconURL: r.favicon_url)
            }
        }
        // Send-tab commands → open on this Mac, then mark consumed.
        if let cmds: [CommandRow] = try? await select("millie_commands", filter: "consumed_at=is.null") {
            for c in cmds where c.kind == "openTab" {
                browser?.newTab(url: c.url, select: false)
                await markConsumed(c.id)
            }
        }

        // Structural merge: Spaces, tabs, Profiles (two-way). Remote tabs land as
        // sleeping tabs — the running Chromium session is untouched until one is
        // selected. Guard suppresses the echo push the merge would otherwise fire.
        guard let browser else { return }
        let rSpaces: [SpaceRow] = (try? await select("millie_spaces")) ?? []
        let rTabs: [TabSyncRow] = (try? await select("millie_tabs")) ?? []
        let rProfiles: [ProfileRow] = (try? await select("millie_profiles")) ?? []
        guard !rSpaces.isEmpty || !rTabs.isEmpty else { return }

        let profiles = rProfiles.map { r in
            r.is_default ? BrowserProfile.default
                         : BrowserProfile(id: r.id, name: r.name, symbol: r.symbol)
        }
        let spaces = rSpaces.sorted { $0.order_index < $1.order_index }.map { r in
            BrowserContext(id: r.id, name: r.name, symbol: r.symbol, theme: r.theme,
                           tabIDs: r.tab_ids, pinnedTabIDs: r.pinned_tab_ids,
                           folders: r.folders, selectedTabID: r.selected_tab_id,
                           profileID: r.profile_id)
        }
        let tabs = rTabs.map { r in
            BrowserStore.RemoteTabRecord(id: r.id, url: r.url, title: r.title,
                                         customTitle: r.custom_title,
                                         profileKey: r.profile_key ?? "default",
                                         faviconURL: r.favicon_url)
        }
        // Tombstones: ids deleted on another device — subtracted from the merge.
        let delTabs: [IDRow] = (try? await select("millie_tabs", filter: "deleted=eq.true")) ?? []
        let delSpaces: [IDRow] = (try? await select("millie_spaces", filter: "deleted=eq.true")) ?? []
        applyingRemote = true
        browser.applyRemoteSync(profiles: profiles, spaces: spaces, tabs: tabs,
                                deletedTabIDs: Set(delTabs.map(\.id)),
                                deletedSpaceIDs: Set(delSpaces.map(\.id)))
        applyingRemote = false
    }

    private func markConsumed(_ id: UUID) async {
        try? await patch("millie_commands", id: id, body: ["consumed_at": ISO.now()])
    }

    // MARK: REST plumbing

    private func upsert<T: Encodable>(_ table: String, _ rows: [T]) async {
        guard !rows.isEmpty else { return }
        do {
            var req = request("/rest/v1/\(table)", method: "POST")
            req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            req.httpBody = try JSONEncoder().encode(rows)
            _ = try await send(req)
        } catch { /* best-effort */ }
    }

    private func select<T: Decodable>(_ table: String, filter: String? = nil) async throws -> [T] {
        var path = "/rest/v1/\(table)?select=*"
        if let filter { path += "&\(filter)" } else { path += "&deleted=eq.false" }
        let req = request(path, method: "GET")
        let data = try await send(req)
        return try JSONDecoder().decode([T].self, from: data)
    }

    private func patch(_ table: String, id: UUID, body: [String: Any]) async throws {
        var req = request("/rest/v1/\(table)?id=eq.\(id.uuidString)", method: "PATCH")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(req)
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any], authed: Bool) async throws -> Data {
        try await postData(path, body: body, authed: authed)
    }

    private func postData(_ path: String, body: [String: Any], authed: Bool) async throws -> Data {
        var req = request(path, method: "POST", authed: authed)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func request(_ path: String, method: String, authed: Bool = true) -> URLRequest {
        // Build manually so query strings (PostgREST filters) aren't escaped.
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        else { req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: request)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            NSLog("MILLIE_SYNC %@ %@ -> %d: %@", request.httpMethod ?? "", request.url?.path ?? "",
                  http.statusCode, String(data: data, encoding: .utf8)?.prefix(400).description ?? "")
            // Token expired → refresh once and retry.
            if http.statusCode == 401, refreshToken != nil {
                await refreshSession()
                var retry = request
                if let accessToken { retry.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
                let (d2, _) = try await URLSession.shared.data(for: retry)
                return d2
            }
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Auth response

private struct AuthSession: Decodable {
    let access_token: String
    let refresh_token: String
    let user: AuthUser?
    struct AuthUser: Decodable { let email: String? }
}

// MARK: - ISO8601

private enum ISO {
    private static let f: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func string(_ d: Date) -> String { f.string(from: d) }
    static func now() -> String { f.string(from: Date()) }
    static func date(_ s: String?) -> Date {
        guard let s else { return Date() }
        return f.date(from: s) ?? plain.date(from: s) ?? Date()
    }
}

// MARK: - Row DTOs (snake_case columns; jsonb maps to nested Codable)

private struct ProfileRow: Codable {
    var id: UUID; var name: String; var symbol: String; var is_default: Bool
    init(_ m: BrowserProfile) { id = m.id; name = m.name; symbol = m.symbol; is_default = m.isDefault }
}

private struct SpaceRow: Codable {
    var id: UUID; var name: String; var symbol: String
    var theme: GradientTheme; var profile_id: UUID?
    var tab_ids: [UUID]; var pinned_tab_ids: [UUID]; var folders: [TabFolder]
    var selected_tab_id: UUID?; var order_index: Int
    init(_ c: BrowserContext, order: Int) {
        id = c.id; name = c.name; symbol = c.symbol; theme = c.theme
        profile_id = c.profileID; tab_ids = c.tabIDs; pinned_tab_ids = c.pinnedTabIDs
        folders = c.folders; selected_tab_id = c.selectedTabID; order_index = order
    }
    // Always emit every key (PostgREST bulk insert requires identical key sets).
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(symbol, forKey: .symbol)
        try c.encode(theme, forKey: .theme); try c.encode(profile_id, forKey: .profile_id)
        try c.encode(tab_ids, forKey: .tab_ids); try c.encode(pinned_tab_ids, forKey: .pinned_tab_ids)
        try c.encode(folders, forKey: .folders); try c.encode(selected_tab_id, forKey: .selected_tab_id)
        try c.encode(order_index, forKey: .order_index)
    }
}

private struct TabSyncRow: Codable {
    var id: UUID; var space_id: UUID?; var url: String; var title: String
    var custom_title: String?; var profile_key: String?; var favicon_url: String?
    var last_accessed_at: String
    init(_ t: BrowserTab, spaceID: UUID?) {
        id = t.id; space_id = spaceID; url = t.urlString; title = t.title
        custom_title = t.customTitle; profile_key = t.profileKey; favicon_url = t.faviconURL
        last_accessed_at = ISO.string(t.lastAccessedAt)
    }
    init(_ t: SessionTab, spaceID: UUID?) {
        id = t.id; space_id = spaceID; url = t.url; title = t.title
        custom_title = t.customTitle; profile_key = t.profileKey; favicon_url = t.faviconURL
        last_accessed_at = ISO.now()
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(space_id, forKey: .space_id)
        try c.encode(url, forKey: .url); try c.encode(title, forKey: .title)
        try c.encode(custom_title, forKey: .custom_title); try c.encode(profile_key, forKey: .profile_key)
        try c.encode(favicon_url, forKey: .favicon_url); try c.encode(last_accessed_at, forKey: .last_accessed_at)
    }
}

/// Minimal decode of `session.json` to reach every tab (including unrealized
/// tabs in inactive Spaces). Mirrors the persisted `PersistedTab` keys; extra
/// root keys (contexts, profiles, …) are ignored.
private struct SessionFile: Decodable { var tabs: [SessionTab] }
private struct SessionTab: Decodable {
    var id: UUID
    var url: String
    var title: String
    var customTitle: String?
    var profileKey: String?
    var faviconURL: String?
}

private struct BookmarkRow: Codable {
    var id: UUID; var url: String; var title: String; var created_at: String
    init(_ m: Bookmark) { id = m.id; url = m.url; title = m.title; created_at = ISO.string(m.createdAt) }
}

private struct HistoryRow: Codable {
    var id: UUID; var url: String; var title: String; var last_visited: String; var visit_count: Int
    init(_ m: HistoryEntry) { id = m.id; url = m.url; title = m.title; last_visited = ISO.string(m.lastVisited); visit_count = m.visitCount }
}

private struct ArchiveRow: Codable {
    var id: UUID; var url: String; var title: String; var favicon_url: String?; var archived_at: String
    init(_ m: ArchivedTab) { id = m.id; url = m.url; title = m.title; favicon_url = m.faviconURL; archived_at = ISO.string(m.archivedAt) }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(url, forKey: .url); try c.encode(title, forKey: .title)
        try c.encode(favicon_url, forKey: .favicon_url); try c.encode(archived_at, forKey: .archived_at)
    }
}

private struct CommandRow: Codable {
    var id: UUID; var kind: String; var url: String
}

/// Just the primary key — used to read tombstoned (deleted=true) ids.
private struct IDRow: Decodable { var id: UUID }
