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
        BrowserSettings.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)
        BoostStore.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)
        RouteStore.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)
        AdBlockStore.shared.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &bag)

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
        // Pull BEFORE the first push. Pushing first overwrote the cloud Space
        // arrays (tab_ids / pinned_tab_ids) with this device's local set before
        // merging — so whichever device launched last with a smaller pin set
        // clobbered everyone else's pins, and they never converged upward. The
        // union merge lives in pull(); do it first so the initial push carries
        // the merged (super)set, not a stale local subset.
        await pull()
        await pushNow()
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
        await pushSettings()

        // A PINNED tab is an intentional keep. Its cloud row may be tombstoned
        // (deleted=true) from another device closing its twin — and the upsert
        // above doesn't carry `deleted`, so merge-duplicates leaves the tombstone
        // in place. Explicitly clear it so the pin propagates as LIVE to every
        // device (incl. iOS) instead of being re-deleted on the next pull. This
        // is the cloud-side complement to applyRemoteSync's local pin protection:
        // for a pinned tab, keep wins over a remote close.
        let pinnedIDs = Set(publicContexts.flatMap { $0.pinnedTabIDs })
            .subtracting(privateTabIDs)
        for id in pinnedIDs {
            try? await patch("millie_tabs", id: id, body: ["deleted": false])
        }

        // Propagate local deletions as tombstones (deleted=true) so other devices
        // drop them instead of resurrecting them on the next union merge. Never
        // tombstone a still-pinned tab (pin wins).
        let (deadTabs, deadSpaces) = browser.drainTombstones()
        for id in deadTabs where !pinnedIDs.contains(id) {
            try? await patch("millie_tabs", id: id, body: ["deleted": true])
        }
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
        await pullSettings()
        // Library merge (safe, additive).
        if let rows: [BookmarkRow] = try? await select("millie_bookmarks") {
            let local = Set(BookmarkStore.shared.bookmarks.map(\.url))
            for r in rows where !local.contains(r.url) {
                _ = BookmarkStore.shared.toggle(url: r.url, title: r.title)
            }
        }
        // History + archive are large (tens of thousands of rows) and the REST
        // API caps a plain select at 1000 rows, so page them: the first sync
        // imports the newest few thousand, later syncs only fetch what changed.
        let historyRows: [HistoryRow] = await pullIncremental("millie_history")
        if !historyRows.isEmpty {
            let local = Set(HistoryStore.shared.entries.map(\.url))
            for r in historyRows where !local.contains(r.url) {
                HistoryStore.shared.record(url: r.url, title: r.title)
            }
        }
        let archiveRows: [ArchiveRow] = await pullIncremental("millie_archive")
        if !archiveRows.isEmpty {
            let local = Set(ArchiveStore.shared.tabs.map(\.url))
            for r in archiveRows where !local.contains(r.url) {
                ArchiveStore.shared.add(url: r.url, title: r.title, faviconURL: r.favicon_url)
            }
        }
        // Send-tab commands → open on this Mac, then mark consumed. Only rows
        // addressed to the Mac (or to no one in particular): iOS now claims
        // `target_device=ios`, and the Mac must leave those for the phone.
        if let cmds: [CommandRow] = try? await select(
            "millie_commands",
            filter: "consumed_at=is.null&or=(target_device.is.null,target_device.eq.macos)") {
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
    var updated_at: String? = nil
    init(_ m: HistoryEntry) { id = m.id; url = m.url; title = m.title; last_visited = ISO.string(m.lastVisited); visit_count = m.visitCount }
}

private struct ArchiveRow: Codable {
    var id: UUID; var url: String; var title: String; var favicon_url: String?; var archived_at: String
    var updated_at: String? = nil
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


// MARK: - Library paging (history / archive)

/// Rows that expose the server's `updated_at` so paging can resume from it.
private protocol UpdatedAtRow { var updated_at: String? { get } }
extension HistoryRow: UpdatedAtRow {}
extension ArchiveRow: UpdatedAtRow {}

extension MillieSync {
    private static let firstSyncLimit = 2000
    private static let pageSize = 1000
    private static let maxPagesPerPull = 5

    /// Fetch rows changed since the last pull, newest-first on the very first
    /// sync (capped) and oldest-first afterwards (so the cursor only moves
    /// forward). The cursor is the max `updated_at` seen, kept per table.
    fileprivate func pullIncremental<T: Decodable>(_ table: String) async -> [T] {
        let cursorKey = "millie.sync.cursor.\(table)"
        let defaults = UserDefaults.standard
        var out: [T] = []
        if let since = defaults.string(forKey: cursorKey) {
            var cursor = since
            for _ in 0..<Self.maxPagesPerPull {
                let enc = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
                guard let page: [T] = try? await select(
                        table,
                        filter: "deleted=eq.false&updated_at=gt.\(enc)&order=updated_at.asc&limit=\(Self.pageSize)"),
                      !page.isEmpty else { break }
                out += page
                if let last = (page.last as? UpdatedAtRow)?.updated_at { cursor = last } else { break }
                defaults.set(cursor, forKey: cursorKey)
                if page.count < Self.pageSize { break }
            }
        } else if let page: [T] = try? await select(
                    table,
                    filter: "deleted=eq.false&order=updated_at.desc&limit=\(Self.firstSyncLimit)") {
            out = page
            if let newest = (page.first as? UpdatedAtRow)?.updated_at {
                defaults.set(newest, forKey: cursorKey)
            }
        }
        return out
    }
}

// MARK: - Settings / Boosts / Routing-rule sync

/// Minimal JSON value so arbitrary preference values round-trip through the
/// `millie_settings.value` jsonb column.
private enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

private struct SettingRow: Codable {
    var key: String
    var value: JSONValue
    var updated_at: String
    var deleted: Bool = false
}

extension MillieSync {
    private enum SK {
        static let boosts = "boosts"
        static let routes = "routes"
        static let pushed = "millie.sync.settings.pushed"
        static let lastPull = "millie.sync.settings.lastPull"
    }

    /// Everything that syncs, as `key -> value`. UserDefaults keys keep their own
    /// names; Boosts and routing rules sync as whole documents.
    private func settingsSnapshot() -> [String: JSONValue] {
        let d = UserDefaults.standard
        var snap: [String: JSONValue] = [:]
        for key in BrowserSettings.syncedDefaultsKeys + [AdBlockStore.allowlistKey] {
            guard let obj = d.object(forKey: key) else { continue }
            if let v = Self.jsonValue(fromDefaults: obj) { snap[key] = v }
        }
        if let v = Self.jsonValue(fromCodable: BoostStore.shared.boosts) { snap[SK.boosts] = v }
        if let v = Self.jsonValue(fromCodable: RouteStore.shared.rules) { snap[SK.routes] = v }
        return snap
    }

    private static func jsonValue(fromDefaults obj: Any) -> JSONValue? {
        switch obj {
        case let data as Data: return .object(["_data": .string(data.base64EncodedString())])
        case let s as String: return .string(s)
        case let arr as [String]: return .array(arr.map { .string($0) })
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        default: return nil
        }
    }

    private static func defaultsObject(from v: JSONValue) -> Any? {
        switch v {
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e9 ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        case .object(let o):
            if case .string(let b64)? = o["_data"] { return Data(base64Encoded: b64) }
            return nil
        case .null: return nil
        }
    }

    private static func jsonValue<T: Encodable>(fromCodable value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from v: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func lastPushed() -> [String: JSONValue]? {
        guard let data = UserDefaults.standard.data(forKey: SK.pushed) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func storeLastPushed(_ m: [String: JSONValue]) {
        if let data = try? JSONEncoder().encode(m) { UserDefaults.standard.set(data, forKey: SK.pushed) }
    }

    /// Push only the settings that changed on this Mac since the last push.
    /// A Mac that has never synced pushes nothing it already received from the
    /// cloud (pullSettings runs first and records those as pushed).
    fileprivate func pushSettings() async {
        let snap = settingsSnapshot()
        var last = lastPushed() ?? [:]
        let changed = snap.filter { last[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        let now = ISO.now()
        let rows = changed.map { SettingRow(key: $0.key, value: $0.value, updated_at: now) }
        do {
            var req = request("/rest/v1/millie_settings?on_conflict=user_id,key", method: "POST")
            req.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            req.httpBody = try JSONEncoder().encode(rows)
            _ = try await send(req)
            for (k, v) in changed { last[k] = v }
            storeLastPushed(last)
        } catch { /* retry on the next push */ }
    }

    /// Apply settings changed on another Mac. On a Mac's first sync the cloud
    /// wins for any key that exists there; afterwards a remote value only
    /// applies when this Mac hasn't changed that setting itself since its last
    /// push (so a local edit is never silently overwritten).
    fileprivate func pullSettings() async {
        let d = UserDefaults.standard
        let firstSync = lastPushed() == nil
        var filter = "order=updated_at.asc&limit=1000"
        if let since = d.string(forKey: SK.lastPull),
           let enc = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            filter += "&updated_at=gt.\(enc)"
        }
        guard let rows: [SettingRow] = try? await select("millie_settings", filter: "deleted=eq.false&\(filter)"),
              !rows.isEmpty else { return }

        let snap = settingsSnapshot()
        var last = lastPushed() ?? [:]
        var touchedDefaults = false, touchedAdblock = false
        applyingRemote = true
        for r in rows {
            let localChangedSinceLastPush = !firstSync && snap[r.key] != last[r.key]
            if snap[r.key] == r.value { last[r.key] = r.value; continue }
            if localChangedSinceLastPush { continue }   // local edit wins; it will push
            switch r.key {
            case SK.boosts:
                if let v = Self.decode([SiteBoost].self, from: r.value) { BoostStore.shared.replaceAll(v) }
            case SK.routes:
                if let v = Self.decode([RoutingRule].self, from: r.value) { RouteStore.shared.replaceAll(v) }
            case AdBlockStore.allowlistKey:
                if case .array(let a) = r.value {
                    AdBlockStore.shared.replaceAllowedHosts(a.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
                    touchedAdblock = true
                }
            default:
                guard BrowserSettings.syncedDefaultsKeys.contains(r.key),
                      let obj = Self.defaultsObject(from: r.value) else { continue }
                d.set(obj, forKey: r.key)
                touchedDefaults = true
            }
            last[r.key] = r.value
        }
        if touchedDefaults { BrowserSettings.shared.reloadFromDefaults() }
        _ = touchedAdblock
        applyingRemote = false
        storeLastPushed(last)
        if let newest = rows.last?.updated_at { d.set(newest, forKey: SK.lastPull) }
    }
}
