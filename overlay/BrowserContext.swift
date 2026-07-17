import Foundation

/// One sidebar "context" — Millie's take on Arc's Spaces. Each context owns its
/// own sidebar organization (pinned tiles, folders, and the ordered set of
/// member tabs) plus an identity (name, glyph) and an optional chrome theme
/// that washes the window while the context is active.
///
/// Tabs themselves live in the store's flat pool; a context references them by
/// id, and every tab belongs to exactly one context. Stale ids are filtered on
/// resolve, so a closed tab simply drops out.
/// One item at the sidebar's root level: a loose tab or a folder. The root is
/// a single mixed, reorderable list (Arc-style) — a tab can live between two
/// folders.
enum RootEntry: Codable, Equatable, Hashable {
    case tab(UUID)
    case folder(UUID)
}

struct BrowserContext: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// Glyph asset shown in the bottom-bar switcher (see `GlyphLibrary`).
    var symbol: String
    /// The chrome wash applied while this context is active. `.none` (empty)
    /// keeps the plain light/dark chrome.
    var theme: GradientTheme
    /// Member tabs in sidebar order. Pinned/foldered tabs keep their slot here
    /// so unpinning restores a sensible position.
    var tabIDs: [UUID]
    /// Tabs surfaced as icon tiles in the pinned grid, in order.
    var pinnedTabIDs: [UUID]
    /// Collapsible folders grouping member tabs.
    var folders: [TabFolder]
    /// Mixed root-level order: loose tabs and (non-tidy) folders in one list.
    /// Self-healing — the store filters stale entries and appends missing ones
    /// (empty = legacy session → folders first, then loose tabs).
    var rootOrder: [RootEntry] = []
    /// The tab that was selected when this context was last active, restored
    /// on switch-back.
    var selectedTabID: UUID?

    /// The Profile (isolated cookies/cache/storage/logins) backing this Space's
    /// tabs. nil = the built-in Default profile. Many Spaces can share one
    /// profile (Arc model). Decodes as nil from pre-Profiles sessions.
    var profileID: UUID?

    /// Incognito Space: its tabs run on an off-the-record engine profile (no
    /// on-disk history/cookies/cache). Private Spaces are never persisted to the
    /// session and never synced. Decodes as false from older sessions.
    var isPrivate: Bool = false

    init(id: UUID = UUID(),
         name: String,
         symbol: String = "glyph-circle",
         theme: GradientTheme = .none,
         tabIDs: [UUID] = [],
         pinnedTabIDs: [UUID] = [],
         folders: [TabFolder] = [],
         selectedTabID: UUID? = nil,
         profileID: UUID? = nil,
         isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.theme = theme
        self.tabIDs = tabIDs
        self.pinnedTabIDs = pinnedTabIDs
        self.folders = folders
        self.selectedTabID = selectedTabID
        self.profileID = profileID
        self.isPrivate = isPrivate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, theme, tabIDs, pinnedTabIDs, folders,
             selectedTabID, profileID, isPrivate, rootOrder
    }

    // Tolerant decode so sessions written before a field existed still load
    // (synthesized Decodable would throw on a missing non-optional key and wipe
    // the user's Spaces). New/optional fields fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "glyph-circle"
        theme = try c.decodeIfPresent(GradientTheme.self, forKey: .theme) ?? .none
        tabIDs = try c.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? []
        pinnedTabIDs = try c.decodeIfPresent([UUID].self, forKey: .pinnedTabIDs) ?? []
        folders = try c.decodeIfPresent([TabFolder].self, forKey: .folders) ?? []
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        rootOrder = try c.decodeIfPresent([RootEntry].self, forKey: .rootOrder) ?? []
    }
}

/// A Profile = an isolated browsing identity (own cookies, cache, storage,
/// logins, extensions), backed by a dedicated persistent Chromium profile.
/// Spaces are assigned to a Profile; many Spaces can share one (Arc model).
struct BrowserProfile: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// Glyph asset for the Profile (see GlyphLibrary).
    var symbol: String
    /// The gradient chrome theme for this Profile. Every Space using this
    /// Profile inherits it. `.none` = no custom wash. Optional-decoded so
    /// sessions saved before per-Profile themes still load.
    var theme: GradientTheme = .none

    /// Stable id of the built-in Default profile, which maps to the primary
    /// Chromium profile (engine key "default").
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var isDefault: Bool { id == BrowserProfile.defaultID }

    /// Key handed to the engine (MoriBrowserView.profileKey): "default" for the
    /// primary profile, otherwise the uuid (→ a "Millie-<uuid>" profile dir).
    var profileKey: String { isDefault ? "default" : id.uuidString }

    static let `default` = BrowserProfile(id: defaultID, name: "Default",
                                          symbol: "glyph-circle")

    init(id: UUID = UUID(), name: String, symbol: String = "glyph-circle",
         theme: GradientTheme = .none) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.theme = theme
    }

    private enum CodingKeys: String, CodingKey { case id, name, symbol, theme }

    // Custom decode so profiles saved before `theme` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "glyph-circle"
        theme = try c.decodeIfPresent(GradientTheme.self, forKey: .theme) ?? .none
    }
}
