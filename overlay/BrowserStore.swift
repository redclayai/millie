import SwiftUI
import AppKit
import Combine

/// Top-level browser state: the open tabs, selection, and chrome toggles.
final class BrowserStore: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: BrowserTab.ID?
    @Published var sidebarVisible: Bool
    /// True while the sidebar's resize handle is being dragged. The web card
    /// freezes its (expensive, async) CEF resize and shows a smooth cover for
    /// the duration, so live dragging stays smooth instead of flickering.
    @Published var isResizingSidebar: Bool = false
    @Published var aiPanelVisible: Bool = false
    @Published var settingsVisible: Bool = false
    @Published var findBarVisible: Bool = false
    /// The keyboard-shortcuts cheat-sheet overlay (⌘/).
    @Published var shortcutsHelpVisible: Bool = false
    /// The new-tab launcher (command palette) overlay.
    @Published var launcherVisible: Bool = false
    /// Bumped every time the launcher is presented, so the AppKit-backed input
    /// can take first responder deterministically even if the host view is
    /// reused across presentations.
    @Published private(set) var launcherFocusRequest: Int = 0
    /// The site-Boost editor overlay (per-site CSS/JS + zapped elements).
    @Published var boostEditorVisible: Bool = false
    /// Host currently loaded into the Boost editor.
    var boostEditorHost: String = ""
    /// The "Import from your old browser" overlay.
    @Published var importPanelVisible: Bool = false
    /// True while the click-to-zap element picker is armed on the active page.
    @Published var zapModeActive: Bool = false
    /// Ephemeral tab shown in the Peek overlay (Little Arc-style transient
    /// preview). Not a member of any context until promoted.
    @Published var peekTab: BrowserTab?
    /// Active custom context menu for a right-clicked link/image, if any.
    @Published var contextMenu: WebContextMenuRequest?
    /// True while the drag-to-select screenshot region picker is armed.
    @Published var captureMode: Bool = false
    /// Seeds the launcher's search field when it opens (e.g. the current URL when
    /// invoked from the address bar). Empty for a blank ⌘T launcher.
    var launcherPrefill: String = ""
    /// When true the launcher edits the *current* tab in place (address-bar
    /// behavior) instead of opening the destination in a fresh tab.
    var launcherEditsCurrentTab: Bool = false
    /// The active find-in-page query, held here so the Find Next / Previous menu
    /// commands can drive the search without the bar being focused.
    @Published var findQuery: String = ""

    // MARK: Contexts / pinned tabs / folders (sidebar organization)

    /// All contexts (Arc-style Spaces). Never empty — there is always at least
    /// one context, and `activeContextID` always points at a member.
    @Published var contexts: [BrowserContext] = []
    /// All Profiles (Arc-style isolation identities). Always non-empty and
    /// always contains the built-in Default; many Spaces may share one profile.
    @Published var profiles: [BrowserProfile] = [.default]
    @Published var activeContextID: BrowserContext.ID = UUID()
    /// Direction of the most recent Space switch (true = moved to a later Space).
    /// Drives the sidebar's directional slide transition.
    @Published var contextSwitchForward: Bool = true
    /// True while the sidebar shows the "Create a Context" flow instead of tabs.
    @Published var contextCreationVisible: Bool = false

    private var activeContextIndex: Int {
        contexts.firstIndex { $0.id == activeContextID } ?? 0
    }

    var activeContext: BrowserContext {
        get {
            contexts.first { $0.id == activeContextID }
                ?? contexts.first
                ?? BrowserContext(name: "Personal")
        }
        set {
            guard let idx = contexts.firstIndex(where: { $0.id == newValue.id }) else { return }
            contexts[idx] = newValue
        }
    }

    /// The active context's pinned tiles. Reads/writes pass through to the
    /// context so existing call sites keep their shape.
    var pinnedTabIDs: [BrowserTab.ID] {
        get { activeContext.pinnedTabIDs }
        set {
            guard contexts.indices.contains(activeContextIndex) else { return }
            contexts[activeContextIndex].pinnedTabIDs = newValue
        }
    }

    /// The active context's folders.
    var folders: [TabFolder] {
        get { activeContext.folders }
        set {
            guard contexts.indices.contains(activeContextIndex) else { return }
            contexts[activeContextIndex].folders = newValue
        }
    }

    /// Folder row that should enter rename mode as soon as it renders.
    @Published var folderIDPendingRename: TabFolder.ID?
    /// Set when a sidebar tab row should enter inline-rename mode; the row
    /// consumes it on appear / change (mirrors folderIDPendingRename).
    @Published var tabIDPendingRename: BrowserTab.ID?

    /// Mirrors theme edits (made through the existing pickers, which write
    /// `settings.gradientTheme`) back into the active context.
    private var themeMirror: AnyCancellable?
    /// Keeps the assistant surface closed while the user-level AI integration
    /// preference is off.
    private var aiIntegrationMirror: AnyCancellable?

    /// Shared, persisted user preferences.
    let settings = BrowserSettings.shared

    /// Drives the sidebar media player from injected-agent broadcasts.
    let media = MediaController()

    /// Recently closed tabs, most-recent last. Powers Reopen Closed Tab and
    /// `chrome.sessions`.
    private struct ClosedTabSession {
        let sessionID: String
        let url: String
        let title: String
        let closedAt: Date
    }
    private var closedTabSessions: [ClosedTabSession] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private let sessionFileURL: URL
    private var sessionSaveScheduled = false
    private var isRestoringSession = false

    /// Repeating timer that drives auto-sleep and auto-archive (see
    /// TabMaintenance.swift). Retained here for the lifetime of the store.
    var maintenanceTimer: Timer?

    /// Repeating timer that polls each live tab's injected media agent and
    /// rebroadcasts its state to `MediaController` (see MediaAgentScripts.swift).
    var mediaPollTimer: Timer?

    private struct PersistedTab: Codable {
        var id: UUID
        var url: String
        var title: String
        /// User-assigned sidebar name (overrides the page title) if set.
        var customTitle: String?
        /// Engine profile key (isolated storage) this tab was created in, so it
        /// reopens in the same Profile/cookie jar after restart.
        var profileKey: String?
        /// Last known favicon URL, so a restored-but-unopened tab can show its
        /// real icon (via the remote-load path) without realizing a CEF browser.
        var faviconURL: String?
        /// Canonical/original URL for a foldered tab (folder-icon reset target).
        var folderHomeURL: String? = nil
        /// User opted this tab out of sleeping/archiving ("Keep Awake").
        /// Optional so sessions saved before this field still decode.
        var keepAwake: Bool? = nil
    }

    private struct PersistedSession: Codable {
        var tabs: [PersistedTab]
        var selectedTabID: UUID?
        /// Arc-style Profiles (isolation identities). Absent in pre-Profiles
        /// sessions → Default is synthesized on restore.
        var profiles: [BrowserProfile]? = nil
        // Legacy (pre-contexts) fields — optional so v2 files omit them and v1
        // files migrate into a single context on restore.
        var pinnedTabIDs: [UUID]? = nil
        var folders: [TabFolder]? = nil
        var spaceName: String? = nil
        var spaceEmoji: String? = nil
        // Contexts (v2).
        var contexts: [BrowserContext]? = nil
        var activeContextID: UUID? = nil
    }

    /// The homepage, sourced from user settings.
    var homeURL: String { settings.homepageURL }

    init() {
        sessionFileURL = BrowserStore.supportDirectory()
            .appendingPathComponent("session.json")
        sidebarVisible = settings.showSidebarOnLaunch
        let startURL = ProcessInfo.processInfo.environment["MORI_START_URL"]
            .flatMap { $0.isEmpty ? nil : $0 }

        isRestoringSession = true
        if let startURL {
            let first = makeTab(url: startURL, title: "New Tab")
            tabs = [first]
            selectedTabID = first.id
        } else if !restoreSession() {
            let first = makeTab(url: settings.homepageURL, title: "New Tab")
            tabs = [first]
            selectedTabID = first.id
        }
        ensureContextIntegrity()
        syncChromePinnedStates()
        // Themes moved from Space → Profile. Migrate: seed each unthemed Profile
        // from the first Space using it that carries a (legacy per-Space) theme,
        // so existing users keep their washes.
        for pi in profiles.indices where profiles[pi].theme.isEmpty {
            if let ctx = contexts.first(where: {
                ($0.profileID ?? BrowserProfile.defaultID) == profiles[pi].id && !$0.theme.isEmpty
            }) {
                profiles[pi].theme = ctx.theme
            }
        }
        // The active Profile's theme drives the chrome while it's active.
        settings.gradientTheme = themeForContext(activeContext)
        isRestoringSession = false

        // Theme edits made anywhere (sidebar popover, Settings) write
        // `settings.gradientTheme`; fold them back into the active Space's
        // Profile so every Space on that Profile shares the wash.
        themeMirror = settings.$gradientTheme
            .dropFirst()
            .sink { [weak self] theme in
                guard let self, !self.isRestoringSession else { return }
                guard self.contexts.indices.contains(self.activeContextIndex) else { return }
                let pid = self.contexts[self.activeContextIndex].profileID ?? BrowserProfile.defaultID
                guard self.profileTheme(pid) != theme else { return }
                self.applyThemeToProfile(pid, theme)
            }
        aiIntegrationMirror = settings.$aiIntegrationEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, !enabled else { return }
                self.closeAIPanelForDisabledIntegration(showToast: false)
            }
        // Let the media controller map an engine broadcast back to its tab.
        media.resolveTab = { [weak self] browserId in
            self?.tabs.first {
                $0.hasRealized && Int($0.browserView.browserIdentifier) == browserId
            }
        }
        installExtensionCommandSmokeIfNeeded()
        startTabMaintenance()
        startMediaPolling()
        // Manage-extensions pages open in the active Space (its Profile).
        ExtensionStore.shared.openURLInActiveSpace = { [weak self] url in
            self?.newTab(url: url)
        }
        // Point the engine at the restored active Space's Profile for extensions.
        syncActiveProfileToEngine()
        // Cross-device sync with the Milly iOS companion (no-op until signed in).
        // attach(browser:) is @MainActor; hop to the main actor since init is
        // nonisolated.
        Task { @MainActor [weak self] in
            guard let self else { return }
            MillieSync.shared.attach(browser: self)
            // Begin Sparkle background update checks (no-op in unsigned dev builds
            // with no appcast configured).
            MillieUpdater.shared.start()
        }
    }

    /// Smoke-test hook: fire extension keyboard commands shortly after launch
    /// so automated runs can verify command dispatch end to end.
    private func installExtensionCommandSmokeIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard let extensionID = env["MORI_EXTENSION_SMOKE_COMMAND_ID"],
              !extensionID.isEmpty
        else { return }
        let commandName = env["MORI_EXTENSION_SMOKE_COMMAND_NAME"] ?? "_execute_action"
        let extraCommandName = env["MORI_EXTENSION_SMOKE_EXTRA_COMMAND_NAME"]
        func fire(_ name: String, after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let command = ExtensionStore.shared.commands.first(where: {
                    $0.extensionID == extensionID && $0.commandName == name
                }) else { return }
                ExtensionStore.shared.activate(command)
            }
        }
        fire(commandName, after: 1.5)
        if let extraCommandName, !extraCommandName.isEmpty {
            fire(extraCommandName, after: 2.0)
        }
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var shouldAutoFocusWebContent: Bool {
        !launcherVisible &&
            !settingsVisible &&
            !findBarVisible &&
            !contextCreationVisible &&
            folderIDPendingRename == nil
    }

    // MARK: Session restore

    private static func supportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("MoriBrowser", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func restoreSession() -> Bool {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let decoded = try? JSONDecoder().decode(PersistedSession.self, from: data)
        else { return false }

        // Restore Profiles (ensure Default is always present and first).
        if let persistedProfiles = decoded.profiles, !persistedProfiles.isEmpty {
            var ps = persistedProfiles
            if !ps.contains(where: { $0.isDefault }) { ps.insert(.default, at: 0) }
            profiles = ps
        }

        let restoredTabs = decoded.tabs
            .filter { !$0.url.isEmpty }
            .map { persisted -> BrowserTab in
                let tab = makeTab(id: persisted.id, url: persisted.url,
                                  title: persisted.title.isEmpty ? "New Tab" : persisted.title,
                                  profileKey: persisted.profileKey ?? "default")
                // Seed the last-known icon so the tab shows it immediately,
                // before (or without) the browser ever being realized.
                tab.faviconURL = persisted.faviconURL
                tab.folderHomeURL = persisted.folderHomeURL
                tab.customTitle = persisted.customTitle
                tab.keepAwake = persisted.keepAwake ?? false
                return tab
            }
        guard !restoredTabs.isEmpty else { return false }

        let liveIDs = Set(restoredTabs.map(\.id))
        tabs = restoredTabs
        selectedTabID = decoded.selectedTabID.flatMap { id in
            liveIDs.contains(id) ? id : nil
        } ?? restoredTabs.first?.id

        if let persistedContexts = decoded.contexts, !persistedContexts.isEmpty {
            contexts = persistedContexts.map { context in
                var copy = context
                copy.tabIDs = copy.tabIDs.filter { liveIDs.contains($0) }
                copy.pinnedTabIDs = copy.pinnedTabIDs.filter { liveIDs.contains($0) }
                copy.folders = copy.folders.map { folder in
                    var f = folder
                    f.tabIDs = f.tabIDs.filter { liveIDs.contains($0) }
                    return f
                }
                if let sel = copy.selectedTabID, !liveIDs.contains(sel) {
                    copy.selectedTabID = nil
                }
                return copy
            }
            activeContextID = decoded.activeContextID
                .flatMap { id in contexts.first { $0.id == id }?.id }
                ?? contexts[0].id
        } else {
            // v1 session: fold the flat pinned/folder state into one context.
            let name = decoded.spaceName.flatMap { $0.isEmpty ? nil : $0 } ?? "Personal"
            let context = BrowserContext(
                name: name,
                symbol: "glyph-circle",
                theme: settings.gradientTheme,
                tabIDs: restoredTabs.map(\.id),
                pinnedTabIDs: (decoded.pinnedTabIDs ?? []).filter { liveIDs.contains($0) },
                folders: (decoded.folders ?? []).map { folder in
                    var copy = folder
                    copy.tabIDs = copy.tabIDs.filter { liveIDs.contains($0) }
                    return copy
                },
                selectedTabID: selectedTabID)
            contexts = [context]
            activeContextID = context.id
        }
        // Back-fill folder-home for items pinned before folderHomeURL was
        // tracked: their resting URL (where they sit at launch) becomes the
        // icon-reset target, so an existing item resets to its real path — not
        // just the site root. New pins already record their exact URL.
        for context in contexts {
            for folder in context.folders {
                for tid in folder.tabIDs {
                    if let t = tab(for: tid), t.folderHomeURL == nil {
                        t.folderHomeURL = t.urlString
                    }
                }
            }
        }
        return true
    }

    /// Post-restore invariants: at least one context exists, the active id is
    /// valid, and every live tab belongs to exactly one context.
    private func ensureContextIntegrity() {
        if contexts.isEmpty {
            let context = BrowserContext(
                name: "Personal",
                symbol: "glyph-circle",
                theme: settings.gradientTheme,
                tabIDs: tabs.map(\.id),
                selectedTabID: selectedTabID)
            contexts = [context]
        }
        if !contexts.contains(where: { $0.id == activeContextID }) {
            activeContextID = contexts[0].id
        }
        var seen = Set<BrowserTab.ID>()
        for i in contexts.indices {
            contexts[i].tabIDs.removeAll { !seen.insert($0).inserted }
        }
        let orphans = tabs.map(\.id).filter { !seen.contains($0) }
        if !orphans.isEmpty {
            contexts[activeContextIndex].tabIDs.append(contentsOf: orphans)
        }
    }

    func scheduleSessionSave() {
        guard !isRestoringSession, !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionSaveScheduled = false
            self.saveSession()
        }
    }

    private func saveSession() {
        guard !tabs.isEmpty else { return }
        // Private Spaces (and their tabs) are incognito — never written to disk.
        let privateTabIDs = Set(contexts.filter(\.isPrivate).flatMap(\.tabIDs))
        let persistableContexts = contexts.filter { !$0.isPrivate }
        let liveIDs = Set(tabs.map(\.id)).subtracting(privateTabIDs)
        var snapshot = persistableContexts.map { context in
            var copy = context
            copy.tabIDs = copy.tabIDs.filter { liveIDs.contains($0) }
            copy.pinnedTabIDs = copy.pinnedTabIDs.filter { liveIDs.contains($0) }
            copy.folders = copy.folders.map { folder in
                var f = folder
                f.tabIDs = f.tabIDs.filter { liveIDs.contains($0) }
                return f
            }
            return copy
        }
        // Keep the active context's remembered selection fresh.
        if let idx = snapshot.firstIndex(where: { $0.id == activeContextID }) {
            snapshot[idx].selectedTabID = selectedTabID
        }
        let state = PersistedSession(
            tabs: tabs.filter { !privateTabIDs.contains($0.id) }.map { PersistedTab(id: $0.id, url: $0.urlString, title: $0.title, customTitle: $0.customTitle, profileKey: $0.profileKey, faviconURL: $0.faviconURL, folderHomeURL: $0.folderHomeURL, keepAwake: $0.keepAwake ? true : nil) },
            selectedTabID: selectedTabID,
            profiles: profiles,
            contexts: snapshot,
            activeContextID: activeContextID
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: sessionFileURL, options: .atomic)
    }

    /// The Profile assigned to a context (Default when unset/unknown).
    func profile(for context: BrowserContext) -> BrowserProfile {
        let id = context.profileID ?? BrowserProfile.defaultID
        return profiles.first { $0.id == id } ?? .default
    }

    /// Engine profile key for a Space. Private Spaces resolve to the engine's
    /// off-the-record profile ("incognito"); everyone else to their Profile.
    func engineKey(for context: BrowserContext) -> String {
        context.isPrivate ? "incognito" : profile(for: context).profileKey
    }

    /// Engine profile key for the active Space's Profile.
    private var activeProfileKey: String { engineKey(for: activeContext) }

    private func makeTab(id: BrowserTab.ID = UUID(), url: String, title: String,
                         profileKey: String = "default") -> BrowserTab {
        let tab = BrowserTab(id: id, url: url, title: title, profileKey: profileKey)
        tab.onRequestNewTab = { [weak self] url in
            self?.newTab(url: url)
        }
        tab.onMetadataChanged = { [weak self] _ in
            self?.scheduleSessionSave()
        }
        tab.onDidNavigate = { [weak self] tab, url in
            self?.applyRouting(for: tab, url: url)
        }
        tab.onThreatBlocked = { [weak self] tab, url in
            self?.presentThreatBlock(tab: tab, url: url)
        }
        return tab
    }

    // MARK: Safe Browsing (phishing / malware block)

    /// An active block: the tab + URL that were stopped, plus the host to show.
    struct ThreatBlock: Equatable {
        let tabID: BrowserTab.ID
        let url: String
        let host: String
    }
    @Published var threatBlock: ThreatBlock?

    private static func threatHost(_ url: String) -> String {
        URLComponents(string: url)?.host?.lowercased() ?? url
    }

    /// A tab stopped a navigation because the destination is on the blocklist.
    private func presentThreatBlock(tab: BrowserTab, url: String) {
        threatBlock = ThreatBlock(tabID: tab.id, url: url, host: Self.threatHost(url))
    }

    /// "Back to safety": leave the bad site — go back if possible, else homepage.
    func dismissThreatBlock() {
        let block = threatBlock
        threatBlock = nil
        guard let block, let tab = tabs.first(where: { $0.id == block.tabID }) else { return }
        if tab.canGoBack { tab.goBack() } else { tab.load(settings.homepageURL) }
    }

    /// "Proceed anyway": remember the bypass for this host and reload the URL.
    func proceedThroughThreat() {
        let block = threatBlock
        threatBlock = nil
        guard let block, let tab = tabs.first(where: { $0.id == block.tabID }) else { return }
        tab.bypassedThreatHosts.insert(Self.threatHost(block.url))
        tab.load(block.url)
    }

    // MARK: Tab management

    @discardableResult
    func newTab(url: String? = nil, select: Bool = true) -> BrowserTab {
        let initialURL = MoriURLRewriter.rewrite(url ?? settings.newTabURL)
        // New tabs adopt the active Space's Profile (isolated storage).
        let tab = makeTab(url: initialURL, title: "New Tab",
                          profileKey: activeProfileKey)
        tabs.append(tab)
        addToActiveContext(tab.id)
        if select { selectTab(tab.id) }
        scheduleSessionSave()
        return tab
    }

    /// Register a freshly created tab as a member of the active context.
    func addToActiveContext(_ id: BrowserTab.ID) {
        guard contexts.indices.contains(activeContextIndex) else { return }
        guard !contexts[activeContextIndex].tabIDs.contains(id) else { return }
        contexts[activeContextIndex].tabIDs.append(id)
    }

    // MARK: - Split view (Zen-style vertical split)

    enum SplitSide { case left, right }
    @Published var splitTabID: BrowserTab.ID?
    @Published var splitSide: SplitSide = .right

    /// Show `id` side-by-side with the selected tab (drag-from-sidebar drop).
    func splitWith(_ id: BrowserTab.ID, side: SplitSide) {
        guard id != selectedTabID, tabs.contains(where: { $0.id == id }) else {
            return
        }
        splitSide = side
        splitTabID = id
        tab(for: id)?.realize()
    }

    func closeSplit() {
        splitTabID = nil
    }

    /// Swap which pane each tab occupies (the split ratio — left-pane width —
    /// stays put; only the tabs trade sides).
    func swapSplitSides() {
        guard splitTabID != nil else { return }
        splitSide = splitSide == .left ? .right : .left
    }

    /// Split two specific tabs — used when one sidebar tab is dropped onto
    /// another. The drop target becomes the front (primary) pane; the dragged
    /// tab fills the other side.
    func splitTabs(_ dragged: BrowserTab.ID, with target: BrowserTab.ID,
                   side: SplitSide = .right) {
        guard dragged != target,
              tabs.contains(where: { $0.id == dragged }),
              tabs.contains(where: { $0.id == target }) else { return }
        selectTab(target)
        splitWith(dragged, side: side)
    }

    func selectTab(_ id: BrowserTab.ID) {
        // A manual selection ends any in-progress MRU cycle (committing it).
        endMRUCycle()
        activate(id, recordAccess: true)
    }

    /// Make `id` the active tab. `recordAccess` updates its MRU recency stamp;
    /// the MRU cycle suppresses it mid-cycle (the frozen snapshot drives the
    /// walk) and stamps only the landed tab when the cycle commits.
    private func activate(_ id: BrowserTab.ID, recordAccess: Bool) {
        // Switching to a tab leaves the settings page — it covers the web card,
        // so it would otherwise stay parked over the newly selected tab.
        if settingsVisible { settingsVisible = false }
        // Selecting a tab that lives in another context (launcher jump,
        // extension activation) brings its context along, Arc-style.
        if let owner = contexts.firstIndex(where: { $0.tabIDs.contains(id) }),
           contexts[owner].id != activeContextID {
            switchContext(to: contexts[owner].id, selectRemembered: false)
        }
        let previous = selectedTabID
        selectedTabID = id
        selectedTab?.realize()
        if recordAccess { selectedTab?.markAccessed() }
        selectedTab?.setChromePinned(isPinned(id))
        selectedTab?.focus()
        if previous != id { scheduleSessionSave() }
    }

    // MARK: New-tab launcher (command palette)

    /// Open the new-tab launcher instead of immediately creating a blank tab, so
    /// the user can search, jump to an open tab, or pick from history first.
    func presentLauncher() {
        launcherPrefill = ""
        launcherEditsCurrentTab = false
        launcherFocusRequest += 1
        withAnimation(Motion.reveal) { launcherVisible = true }
    }

    /// Address-bar behavior: open the launcher seeded with the current tab's URL
    /// (text pre-selected), navigating the *current* tab on commit rather than
    /// spawning a new one. Re-invoking while it's already up toggles it closed.
    func presentLauncherForCurrentTab() {
        if launcherVisible {
            // Already up (e.g. ⌘L pressed twice, or while a ⌘T launcher is open):
            // collapse it rather than stacking another invocation.
            dismissLauncher()
            return
        }
        launcherPrefill = selectedTab?.displayURL ?? ""
        launcherEditsCurrentTab = true
        launcherFocusRequest += 1
        withAnimation(Motion.reveal) { launcherVisible = true }
    }

    /// ⌘T behavior: open the launcher, or close it again if it's already up.
    func toggleLauncher() {
        if launcherVisible {
            dismissLauncher()
        } else {
            presentLauncher()
        }
    }

    func dismissLauncher() {
        launcherEditsCurrentTab = false
        withAnimation(Motion.reveal) { launcherVisible = false }
    }

    /// Commit typed launcher text. In address-bar mode this loads into the
    /// current tab; otherwise it opens a fresh tab. A blank commit makes a new
    /// blank tab only in new-tab mode (in edit mode it's a no-op).
    func launcherOpen(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let editing = launcherEditsCurrentTab && selectedTab != nil
        dismissLauncher()
        guard !text.isEmpty else {
            if !editing { newTab() }
            return
        }
        if editing {
            navigate(text)
        } else {
            newTab(url: URLInterpreter.resolve(text, settings: settings), select: true)
        }
    }

    /// Open a chosen destination (history / suggestion). Loads into the current
    /// tab in address-bar mode, or a fresh tab otherwise.
    func launcherOpen(url: String) {
        let editing = launcherEditsCurrentTab && selectedTab != nil
        dismissLauncher()
        if editing {
            navigate(url)
        } else {
            newTab(url: url, select: true)
        }
    }

    /// Jump to an already-open tab from the launcher.
    func launcherSwitch(to id: BrowserTab.ID) {
        dismissLauncher()
        selectTab(id)
    }

    func closeTab(_ id: BrowserTab.ID,
                  allowPinned: Bool = false,
                  allowFolderRemoval: Bool = false,
                  forceRemove: Bool = false) {
        if id == splitTabID || id == selectedTabID { splitTabID = nil }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Pinned tabs are permanent: a close gesture (Cmd-W, close button) is
        // ignored. They can only be removed by explicitly unpinning them.
        if contexts.contains(where: { $0.pinnedTabIDs.contains(id) }), !allowPinned { return }
        // Tabs inside a USER folder are a persistent collection (Zen/Arc-style).
        // Closing KEEPS the entry: an awake tab unloads (sleeps, staying pinned
        // in the folder) on the first close; an already-asleep tab is removed
        // only by the × button (allowFolderRemoval) on a second press — Cmd-W
        // leaves it. `forceRemove` (the "Close Tab" menu item / bulk closes)
        // removes it immediately regardless. Tidy groups are exempt: they're
        // temporary, so closing one of their tabs just closes it.
        if !forceRemove,
           contexts.contains(where: { $0.folders.contains { !$0.isTidy && $0.tabIDs.contains(id) } }) {
            // An unrealized tab (restored, never loaded) counts as already
            // unloaded — sleep() is a no-op on it, so treating it as "awake"
            // would loop in this branch forever and the × could never remove it.
            let unloaded = tab(for: id).map { $0.isAsleep || !$0.hasRealized } ?? true
            if !unloaded {
                unloadFolderedTab(id)   // first close → keep pinned, just unload
                return
            }
            if !allowFolderRemoval {
                return                  // Cmd-W on an already-unloaded tab: keep it
            }
            // unloaded + × button → fall through to a real close (removes it)
        }
        let tab = tabs[idx]
        // Propagate this close to other devices (incognito tabs never sync).
        if tab.profileKey != "incognito" { pendingTabTombstones.insert(id) }
        // Capture the engine id before teardown so the media player drops it.
        let mediaBrowserId = tab.hasRealized ? Int(tab.browserView.browserIdentifier) : 0
        // Remember where it was pointing so Cmd-Shift-T can bring it back.
        let url = tab.urlString
        if url != "about:blank", !url.isEmpty {
            closedTabSessions.append(ClosedTabSession(sessionID: UUID().uuidString,
                                                      url: url,
                                                      title: tab.title,
                                                      closedAt: Date()))
            if closedTabSessions.count > 25 { closedTabSessions.removeFirst() }
        }
        // Remember its position among the active context's visible tabs so the
        // next selection stays in place (and in this context).
        let contextOrder = orderedTabsForShortcuts.map(\.id)
        let closedContextIndex = contextOrder.firstIndex(of: id)

        tab.close()
        media.forgetTab(browserId: mediaBrowserId)
        // Animate the removal so the sidebar row fades + shrinks and the rows
        // below collapse up into the gap, matching Zen's `animateItemClose`.
        withAnimation(Motion.tabClose) {
            tabs.remove(at: idx)
            for contextIndex in contexts.indices {
                contexts[contextIndex].tabIDs.removeAll { $0 == id }
                contexts[contextIndex].pinnedTabIDs.removeAll { $0 == id }
                for folderIndex in contexts[contextIndex].folders.indices {
                    contexts[contextIndex].folders[folderIndex].tabIDs.removeAll { $0 == id }
                }
                // A tidy group is just its tabs — drop it once the last closes
                // (user folders persist empty; they're deliberate collections).
                contexts[contextIndex].folders.removeAll { $0.isTidy && $0.tabIDs.isEmpty }
                if contexts[contextIndex].selectedTabID == id {
                    contexts[contextIndex].selectedTabID = nil
                }
            }
        }
        if tabs.isEmpty {
            // Always keep at least one tab open.
            let fresh = newTab(select: true)
            selectedTabID = fresh.id
            return
        }
        if selectedTabID == id {
            let remaining = orderedTabsForShortcuts
            if remaining.isEmpty {
                // The active context just emptied; keep it alive with a fresh tab.
                _ = newTab(select: true)
            } else {
                let newIndex = min(closedContextIndex ?? remaining.count - 1,
                                   remaining.count - 1)
                selectTab(remaining[newIndex].id)
            }
        }
        scheduleSessionSave()
    }

    /// Close gesture for a tab that lives in a folder: unload its content
    /// (`sleep`) instead of destroying it, so the folder keeps the entry, and
    /// move selection to a neighbour — the previous tab in the sidebar order, or
    /// the next one, or a fresh new-tab page when nothing else is open.
    private func unloadFolderedTab(_ id: BrowserTab.ID) {
        guard let tab = tab(for: id) else { return }
        if selectedTabID == id {
            let ordered = orderedTabsForShortcuts
            let neighbor: BrowserTab? = ordered.firstIndex(where: { $0.id == id })
                .flatMap { pos in
                    if pos - 1 >= 0 { return ordered[pos - 1] }
                    if pos + 1 < ordered.count { return ordered[pos + 1] }
                    return nil
                }
            if let neighbor {
                selectTab(neighbor.id)
            } else {
                _ = newTab(select: true)
            }
        }
        // Sleep after selection has moved away so the CEF browser tears down
        // cleanly; the row dims to its asleep state. Pause + forget its media so
        // audio stops and the player doesn't linger.
        let mediaBrowserId = tab.hasRealized ? Int(tab.browserView.browserIdentifier) : 0
        if tab.hasRealized {
            tab.browserView.sendMediaCommand("pause", value: 0)
        }
        withAnimation(Motion.snappy) { tab.sleep() }
        media.forgetTab(browserId: mediaBrowserId)
        scheduleSessionSave()
    }

    /// Folder-icon tap: send a foldered tab back to its original ("home") URL —
    /// the URL it had when added to the folder, or the site origin as a fallback
    /// for entries pinned before this was tracked. Selects (and wakes) the tab.
    func resetFolderedTabToHome(_ id: BrowserTab.ID) {
        guard let tab = tab(for: id) else { return }
        let home = tab.folderHomeURL ?? Self.originURL(of: tab.urlString)
        selectTab(id)
        if !home.isEmpty { tab.load(home) }
    }

    /// `scheme://host[:port]/` for a URL string, or "" if it has no host.
    static func originURL(of urlString: String) -> String {
        guard let comps = URLComponents(string: urlString),
              let scheme = comps.scheme, let host = comps.host, !host.isEmpty else {
            return ""
        }
        var s = "\(scheme)://\(host)"
        if let port = comps.port { s += ":\(port)" }
        return s + "/"
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        scheduleSessionSave()
    }

    @discardableResult
    func duplicateTab(_ id: BrowserTab.ID, select: Bool = true) -> BrowserTab? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let duplicate = makeTab(url: tab.urlString, title: tab.title,
                                profileKey: tab.profileKey)
        duplicate.faviconURL = tab.faviconURL
        let sourceIndex = tabs.firstIndex { $0.id == id } ?? tabs.count - 1
        tabs.insert(duplicate, at: min(sourceIndex + 1, tabs.count))
        // The copy lands in the source tab's context, right after the original.
        if let owner = contexts.firstIndex(where: { $0.tabIDs.contains(id) }) {
            let at = contexts[owner].tabIDs.firstIndex(of: id).map { $0 + 1 }
                ?? contexts[owner].tabIDs.count
            contexts[owner].tabIDs.insert(duplicate.id, at: at)
        } else {
            addToActiveContext(duplicate.id)
        }
        if select { selectTab(duplicate.id) }
        scheduleSessionSave()
        return duplicate
    }

    func copyURL(of id: BrowserTab.ID) {
        guard let url = tabs.first(where: { $0.id == id })?.urlString,
              !url.isEmpty
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    /// Copy the active tab's link to the clipboard, confirming with a toast.
    /// Backs the ⌘⇧C shortcut.
    func copyCurrentTabURL() {
        guard let url = selectedTab?.urlString, !url.isEmpty else {
            ToastCenter.shared.show("No link to copy", icon: "xmark", style: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
        ToastCenter.shared.show("Link copied to clipboard", icon: "link", style: .success)
    }

    func closeOtherTabs(than id: BrowserTab.ID) {
        let context = activeContext
        let ids = context.tabIDs
            .filter { $0 != id && !context.pinnedTabIDs.contains($0) }
        for tabID in ids {
            closeTab(tabID)
        }
        selectTab(id)
    }

    func closeTabsToRight(of id: BrowserTab.ID) {
        let context = activeContext
        guard let index = context.tabIDs.firstIndex(of: id),
              index + 1 < context.tabIDs.count
        else { return }
        let ids = context.tabIDs[(index + 1)...]
            .filter { !context.pinnedTabIDs.contains($0) }
        for tabID in ids {
            closeTab(tabID)
        }
        selectTab(id)
    }

    func hasClosableTabsToRight(of id: BrowserTab.ID) -> Bool {
        let context = activeContext
        guard let index = context.tabIDs.firstIndex(of: id),
              index + 1 < context.tabIDs.count
        else { return false }
        return context.tabIDs[(index + 1)...].contains { !context.pinnedTabIDs.contains($0) }
    }

    /// Reopen the most recently closed tab, restoring its last URL.
    func reopenClosedTab() {
        guard let session = closedTabSessions.popLast() else { return }
        _ = newTab(url: session.url, select: true)
    }

    /// Whether there's a recently-closed tab to reopen (gates the menu item).
    var canReopenClosedTab: Bool { !closedTabSessions.isEmpty }

    /// Select the tab at a 1-based slot (Cmd-1…Cmd-9). By convention the
    /// highest slot, 9, always jumps to the *last* tab regardless of count.
    ///
    /// Slots follow the sidebar's visual order — pinned tabs first — so Cmd-1
    /// lands on the first pinned tab. Recomputed on each press, so it tracks
    /// pinning/unpinning dynamically.
    func selectTab(atOrdinal ordinal: Int) {
        let ordered = orderedTabsForShortcuts
        guard !ordered.isEmpty else { return }
        let index = ordinal >= 9 ? ordered.count - 1 : ordinal - 1
        guard ordered.indices.contains(index) else { return }
        selectTab(ordered[index].id)
    }

    /// Tab order used by the Cmd-1…Cmd-9 shortcuts: the active context's pinned
    /// tabs first (matching the sidebar), then its remaining tabs in order.
    private var orderedTabsForShortcuts: [BrowserTab] {
        let context = activeContext
        let pinned = context.pinnedTabIDs.compactMap { tab(for: $0) }
        let rest = context.tabIDs
            .filter { !context.pinnedTabIDs.contains($0) }
            .compactMap { tab(for: $0) }
        return pinned + rest
    }

    /// Cycle to the next/previous tab in the active context, wrapping around.
    func selectNextTab() { cycleTab(by: 1) }
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        switch settings.tabCycleOrder {
        case .recentlyUsed: cycleTabByRecency(by: delta)
        case .inOrder:      cycleTabByPosition(by: delta)
        }
    }

    private func cycleTabByPosition(by delta: Int) {
        let ordered = orderedTabsForShortcuts
        guard ordered.count > 1,
              let current = ordered.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        let next = (current + delta + ordered.count) % ordered.count
        selectTab(ordered[next].id)
    }

    // MARK: MRU tab cycling (Arc/Dia-style Ctrl+Tab)

    private var mruCycleOrder: [BrowserTab.ID] = []
    private var mruCycleIndex = 0
    private var mruCycling = false
    private var mruCommitWork: DispatchWorkItem?

    /// Drives the Ctrl+Tab preview switcher HUD. Visible only while a cycle is in
    /// progress; `switcherTabIDs` is the frozen MRU snapshot and `switcherIndex`
    /// is the highlighted (landing) position.
    @Published private(set) var switcherVisible = false
    @Published private(set) var switcherTabIDs: [BrowserTab.ID] = []
    @Published private(set) var switcherIndex = 0

    /// Walk tabs in most-recently-used order. A "cycle session" freezes a
    /// recency snapshot on the first press so repeated presses step through it
    /// without the act of switching scrambling the order; the session commits
    /// (promoting the landed tab to most-recent) on the next manual action or a
    /// short idle debounce.
    private func cycleTabByRecency(by delta: Int) {
        if !mruCycling {
            mruCycleOrder = orderedTabsForShortcuts
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .map(\.id)
            guard mruCycleOrder.count > 1 else { return }
            mruCycleIndex = selectedTabID.flatMap { mruCycleOrder.firstIndex(of: $0) } ?? 0
            mruCycling = true
            switcherTabIDs = mruCycleOrder
            switcherVisible = true
        }
        guard mruCycleOrder.count > 1 else { return }
        mruCycleIndex = (mruCycleIndex + delta + mruCycleOrder.count) % mruCycleOrder.count
        switcherIndex = mruCycleIndex
        activate(mruCycleOrder[mruCycleIndex], recordAccess: false)
        scheduleMRUCommit()
    }

    private func scheduleMRUCommit() {
        mruCommitWork?.cancel()
        // No key-release signal reaches the shortcut layer, so commit a short
        // beat after the user stops pressing Ctrl+Tab.
        let work = DispatchWorkItem { [weak self] in self?.endMRUCycle() }
        mruCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// A modifier/key release from the shortcut layer. Releasing Control while
    /// an MRU cycle is running commits it immediately (Arc/Dia behaviour): the
    /// landed tab becomes most-recent, so the *next* Ctrl+Tab toggles back to
    /// the one before it instead of walking deeper. Tab key-ups with Control
    /// still held keep the cycle open so a held Ctrl+Tab still walks.
    func handleShortcutRelease(_ event: NSEvent) {
        guard mruCycling else { return }
        if !event.modifierFlags.contains(.control) {
            endMRUCycle()
        }
    }

    /// End an in-progress MRU cycle, promoting the landed tab to most-recent.
    private func endMRUCycle() {
        mruCommitWork?.cancel()
        mruCommitWork = nil
        guard mruCycling else { return }
        mruCycling = false
        switcherVisible = false
        selectedTab?.markAccessed()
        scheduleSessionSave()
    }

    // MARK: Navigation on the active tab

    func goBack() { selectedTab?.goBack() }
    func goForward() { selectedTab?.goForward() }
    func reload() { selectedTab?.reload() }
    func reloadIgnoringCache() { selectedTab?.reloadIgnoringCache() }
    func stop() { selectedTab?.stop() }

    func zoomIn() { selectedTab?.zoomIn() }
    func zoomOut() { selectedTab?.zoomOut() }
    func resetZoom() { selectedTab?.resetZoom() }

    func toggleDevTools() { selectedTab?.toggleDevTools() }
    func printPage() { selectedTab?.printPage() }

    // MARK: Find-in-page

    func showFindBar() {
        withAnimation(Motion.snappy) { findBarVisible = true }
        if !findQuery.isEmpty { selectedTab?.find(findQuery, forward: true) }
    }

    func hideFindBar() {
        selectedTab?.stopFind()
        withAnimation(Motion.snappy) { findBarVisible = false }
    }

    func toggleFindBar() {
        if findBarVisible { hideFindBar() } else { showFindBar() }
    }

    /// Re-run the current query, advancing to the next/previous match. Opens the
    /// bar first if it's closed (Cmd-G with no bar yet).
    func findNext(forward: Bool) {
        guard !findQuery.isEmpty else { showFindBar(); return }
        if !findBarVisible { showFindBar() }
        selectedTab?.find(findQuery, forward: forward)
    }

    /// Interpret omnibox text as either a URL or a search query.
    func navigate(_ input: String) {
        // Loading a URL into the current tab means the user wants the page, not
        // the settings page that's covering it.
        if settingsVisible { settingsVisible = false }
        let resolved = MoriURLRewriter.rewrite(
            URLInterpreter.resolve(input, settings: settings))
        selectedTab?.load(resolved)
    }

    /// Send the active tab to the configured homepage.
    func goHome() {
        selectedTab?.load(settings.homepageURL)
    }

    func toggleSidebar() {
        withAnimation(Motion.snappy) { sidebarVisible.toggle() }
    }

    func openAIPanel() {
        guard prepareAIPanelOpen() else { return }
        withAnimation(Motion.reveal) { aiPanelVisible = true }
    }

    func toggleAIPanel() {
        guard prepareAIPanelOpen() else { return }
        withAnimation(Motion.reveal) { aiPanelVisible.toggle() }
    }

    private func prepareAIPanelOpen() -> Bool {
        guard settings.aiIntegrationEnabled else {
            closeAIPanelForDisabledIntegration(showToast: true)
            return false
        }
        return true
    }

    private func closeAIPanelForDisabledIntegration(showToast: Bool) {
        if aiPanelVisible {
            withAnimation(Motion.reveal) { aiPanelVisible = false }
        } else {
            aiPanelVisible = false
        }
        if showToast {
            ToastCenter.shared.show("AI integration is off", icon: "sparkles", style: .warning)
        }
    }

    func toggleSettings() {
        settingsVisible.toggle()
    }

    func prepareForTermination() {
        // Make sure the cookie jar is written before we tear CEF down, so
        // sessions reliably survive the quit.
        saveSession()
        MoriPrivacy.flushCookies()
        for tab in tabs { tab.close() }
    }

    /// Clear browsing data: history (and optionally cookies / cache). Cookies and
    /// cache are cleared across EVERY Profile (default + all isolated Profiles),
    /// so this is a true "clear everything" privacy action.
    func clearBrowsingData(history: Bool = true,
                           cookies: Bool = true,
                           cache: Bool = true,
                           downloads: Bool = false) {
        if history { HistoryStore.shared.clear() }
        let keys = profiles.map { $0.profileKey }
        if cookies { MoriPrivacy.clearCookies(forProfileKeys: keys) }
        if cache { MoriPrivacy.clearCache(forProfileKeys: keys) }
        if downloads { DownloadStore.shared.clearAllRecords() }
    }

    // MARK: - Pinned tabs & folders

    func tab(for id: BrowserTab.ID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    /// Tabs in the pinned grid (stale ids are skipped).
    var pinnedTabs: [BrowserTab] {
        pinnedTabIDs.compactMap { tab(for: $0) }
    }

    private var folderedIDs: Set<BrowserTab.ID> {
        Set(folders.flatMap { $0.tabIDs })
    }

    /// The active context's tabs that are neither pinned nor inside a folder,
    /// in the context's sidebar order.
    var looseTabs: [BrowserTab] {
        let context = activeContext
        let foldered = folderedIDs
        return context.tabIDs
            .filter { !context.pinnedTabIDs.contains($0) && !foldered.contains($0) }
            .compactMap { tab(for: $0) }
    }

    func tabs(in folder: TabFolder) -> [BrowserTab] {
        folder.tabIDs.compactMap { tab(for: $0) }
    }

    func isPinned(_ id: BrowserTab.ID) -> Bool { pinnedTabIDs.contains(id) }

    func togglePin(_ id: BrowserTab.ID) {
        withAnimation(Motion.snappy) {
            if pinnedTabIDs.contains(id) {
                pinnedTabIDs.removeAll { $0 == id }
            } else {
                detachFromFolders(id)
                pinnedTabIDs.append(id)
            }
            syncChromePinnedState(for: id)
            scheduleSessionSave()
        }
    }

    func syncChromePinnedStates() {
        let pinnedIDs = Set(contexts.flatMap(\.pinnedTabIDs))
        for tab in tabs {
            tab.setChromePinned(pinnedIDs.contains(tab.id))
        }
    }

    func syncChromePinnedState(for id: BrowserTab.ID) {
        tab(for: id)?.setChromePinned(contexts.contains {
            $0.pinnedTabIDs.contains(id)
        })
    }

    // MARK: Folder management

    @discardableResult
    func addFolder(name: String = "New Folder", isTidy: Bool = false) -> TabFolder {
        let folder = TabFolder(name: name, isExpanded: true, isTidy: isTidy)
        withAnimation(Motion.snappy) { folders.append(folder) }
        scheduleSessionSave()
        return folder
    }

    /// Dissolve all "Tidy Tabs" groups in the active Space: their tabs return to
    /// the loose list and the temporary groups are removed. (Permanent, user-made
    /// folders are never touched.)
    func clearTidyGroups() {
        guard folders.contains(where: { $0.isTidy }) else { return }
        withAnimation(Motion.snappy) {
            folders.removeAll { $0.isTidy }
        }
        scheduleSessionSave()
    }

    @discardableResult
    func addFolderForEditing(name: String = "New Folder") -> TabFolder {
        let folder = addFolder(name: name)
        folderIDPendingRename = folder.id
        return folder
    }

    func consumeFolderRenameRequest(for folderID: TabFolder.ID) {
        guard folderIDPendingRename == folderID else { return }
        folderIDPendingRename = nil
    }

    // MARK: Tab rename (custom sidebar names)

    /// Give a tab a custom sidebar name. An empty/whitespace name clears it,
    /// reverting the row to the live page title.
    func renameTab(_ id: BrowserTab.ID, to name: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        scheduleSessionSave()
    }

    /// Clear a custom name so the tab follows its page title again.
    func resetTabName(_ id: BrowserTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.customTitle = nil
        scheduleSessionSave()
    }

    /// Ask the matching sidebar row to enter inline-rename mode.
    func requestTabRename(_ id: BrowserTab.ID) {
        tabIDPendingRename = id
    }

    func consumeTabRenameRequest(for id: BrowserTab.ID) {
        guard tabIDPendingRename == id else { return }
        tabIDPendingRename = nil
    }

    func toggleFolder(_ folderID: TabFolder.ID) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        withAnimation(Motion.snappy) { folders[idx].isExpanded.toggle() }
        scheduleSessionSave()
    }

    func renameFolder(_ folderID: TabFolder.ID, to name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx].name = name
        scheduleSessionSave()
    }

    /// Delete a folder; its tabs fall back into the loose list.
    func deleteFolder(_ folderID: TabFolder.ID) {
        withAnimation(Motion.snappy) {
            folders.removeAll { $0.id == folderID }
        }
        scheduleSessionSave()
    }

    /// Dissolve a folder: the folder disappears, its tabs stay open and fall
    /// back to the loose list (Dia's "Separate Tabs").
    func separateFolderTabs(_ folderID: TabFolder.ID) {
        deleteFolder(folderID)
        ToastCenter.shared.show("Tabs separated", icon: "folder.badge.minus", style: .success)
    }

    /// Close a folder AND all of its tabs.
    func closeFolderAndTabs(_ folderID: TabFolder.ID) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        for id in folder.tabIDs { closeTab(id, forceRemove: true) }
        deleteFolder(folderID)
    }

    /// Duplicate a folder: fresh tabs for each member (same URLs), collected in
    /// a new folder right after the original.
    func duplicateFolder(_ folderID: TabFolder.ID) {
        guard let ctxIdx = contexts.firstIndex(where: { $0.folders.contains { $0.id == folderID } }),
              let folder = contexts[ctxIdx].folders.first(where: { $0.id == folderID })
        else { return }
        let copies = folder.tabIDs.compactMap { duplicateTab($0, select: false)?.id }
        guard !copies.isEmpty else { return }
        let copyFolder = TabFolder(name: folder.name + " copy", symbol: folder.symbol,
                                   isExpanded: true, tabIDs: copies,
                                   isTidy: folder.isTidy, colorHex: folder.colorHex)
        if let pos = contexts[ctxIdx].folders.firstIndex(where: { $0.id == folderID }) {
            contexts[ctxIdx].folders.insert(copyFolder, at: pos + 1)
        } else {
            contexts[ctxIdx].folders.append(copyFolder)
        }
        scheduleSessionSave()
    }

    /// Copy every tab in the folder as a Markdown link list.
    func copyFolderLinksAsMarkdown(_ folderID: TabFolder.ID) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        let lines = folder.tabIDs.compactMap { id -> String? in
            guard let t = tab(for: id), !t.urlString.isEmpty else { return nil }
            let title = t.displayTitle.isEmpty ? t.urlString : t.displayTitle
            return "- [\(title)](\(t.urlString))"
        }
        guard !lines.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
        ToastCenter.shared.show("\(lines.count) link\(lines.count == 1 ? "" : "s") copied",
                                icon: "doc.on.doc", style: .success)
    }

    /// Set (or clear, with nil = derive from the first tab's favicon) a
    /// folder's accent color.
    func setFolderColor(_ folderID: TabFolder.ID, hex: String?) {
        for ci in contexts.indices {
            if let fi = contexts[ci].folders.firstIndex(where: { $0.id == folderID }) {
                contexts[ci].folders[fi].colorHex = hex
            }
        }
        scheduleSessionSave()
    }

    /// Move a tab into a folder, removing it from any other folder / the pins.
    func addTab(_ tabID: BrowserTab.ID, toFolder folderID: TabFolder.ID) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        withAnimation(Motion.snappy) {
            detachFromFolders(tabID)
            pinnedTabIDs.removeAll { $0 == tabID }
            folders[idx].tabIDs.append(tabID)
            folders[idx].isExpanded = true
        }
        // Remember the URL it was pinned at so the folder-icon tap can reset here.
        if let t = tab(for: tabID), t.folderHomeURL == nil {
            t.folderHomeURL = t.urlString
        }
        scheduleSessionSave()
    }

    func removeTabFromFolders(_ tabID: BrowserTab.ID) {
        withAnimation(Motion.snappy) { detachFromFolders(tabID) }
        scheduleSessionSave()
    }

    private func detachFromFolders(_ tabID: BrowserTab.ID) {
        for i in folders.indices {
            folders[i].tabIDs.removeAll { $0 == tabID }
        }
    }

    /// Set a folder's glyph (the icon shown in the pocket). Empty/default is
    /// "folder", which renders the plain pocket with no inner glyph.
    func setFolderSymbol(_ folderID: TabFolder.ID, symbol: String) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx].symbol = symbol
        scheduleSessionSave()
    }

    // MARK: - Tidy tabs (deterministic clean-up & grouping)

    /// One-click clean-up of the active Space: close duplicate loose tabs, then
    /// group the rest by site into folders. Pinned and already-foldered tabs are
    /// never touched. Reports the result as a toast.
    func tidyTabs() {
        let closed = closeDuplicateLooseTabs()
        let grouped = groupLooseTabsBySite()
        if closed > 0 || grouped > 0 { scheduleSessionSave() }

        let message: String
        if closed == 0 && grouped == 0 {
            message = "Tabs are already tidy"
        } else {
            var parts: [String] = []
            if closed > 0 {
                parts.append("closed \(closed) duplicate\(closed == 1 ? "" : "s")")
            }
            if grouped > 0 {
                parts.append("grouped \(grouped) tab\(grouped == 1 ? "" : "s")")
            }
            message = "Tidied — " + parts.joined(separator: " · ")
        }
        ToastCenter.shared.show(
            message,
            icon: "rectangle.3.group",
            style: (closed == 0 && grouped == 0) ? .info : .success)
    }

    /// Close duplicate loose tabs (same normalized URL), keeping one per URL —
    /// the selected tab if it's among the duplicates, otherwise the first in
    /// sidebar order. Pinned/foldered tabs are left alone. Returns the count.
    @discardableResult
    func closeDuplicateLooseTabs() -> Int {
        let loose = looseTabs
        var keeperByKey: [String: BrowserTab.ID] = [:]
        if let sel = selectedTabID,
           let selTab = loose.first(where: { $0.id == sel }) {
            let key = Self.tidyURLKey(selTab.urlString)
            if !key.isEmpty { keeperByKey[key] = sel }
        }
        var toClose: [BrowserTab.ID] = []
        for tab in loose {
            let key = Self.tidyURLKey(tab.urlString)
            guard !key.isEmpty else { continue }
            if let keep = keeperByKey[key] {
                if keep != tab.id { toClose.append(tab.id) }
            } else {
                keeperByKey[key] = tab.id
            }
        }
        for id in toClose { closeTab(id, forceRemove: true) }
        return toClose.count
    }

    /// Group the active Space's loose tabs by site (registrable domain) into
    /// folders. Any site with two or more loose tabs gets a folder — reusing one
    /// already named for that site, else creating it. Returns the number moved.
    @discardableResult
    func groupLooseTabsBySite() -> Int {
        let loose = looseTabs
        var order: [String] = []
        var bySite: [String: [BrowserTab.ID]] = [:]
        for tab in loose {
            guard let site = Self.tidySiteName(tab.urlString) else { continue }
            if bySite[site] == nil { order.append(site) }
            bySite[site, default: []].append(tab.id)
        }
        var moved = 0
        for site in order {
            guard let ids = bySite[site], ids.count >= 2 else { continue }
            // Reuse an existing TIDY group for this site; never fold into a
            // permanent user folder that happens to share the name. New groups
            // are marked isTidy so they render in the temporary section.
            let folder = folders.first {
                $0.isTidy && $0.name.caseInsensitiveCompare(site) == .orderedSame
            } ?? addFolder(name: site, isTidy: true)
            for id in ids {
                addTab(id, toFolder: folder.id)
                moved += 1
            }
        }
        return moved
    }

    /// Normalized de-dup key for a URL: scheme+host+path (lowercased host, no
    /// trailing slash, fragment dropped, query kept). Falls back to the trimmed
    /// raw string for non-URL entries.
    static func tidyURLKey(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString),
              let host = comps.host, !host.isEmpty else {
            return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        comps.fragment = nil
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        var key = (comps.scheme?.lowercased() ?? "") + "://" + host.lowercased() + path
        if let query = comps.query, !query.isEmpty { key += "?" + query }
        return key
    }

    /// Display site name for grouping — the registrable domain, approximated as
    /// the last two host labels with a leading "www." stripped. Returns nil for
    /// host-less URLs (chrome://, about:, file:) so internal pages stay loose.
    static func tidySiteName(_ urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host?.lowercased(),
              !host.isEmpty else { return nil }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let labels = trimmed.split(separator: ".")
        guard labels.count > 2 else { return trimmed }
        return labels.suffix(2).joined(separator: ".")
    }

    // MARK: - Detached tab windows (tear-off)

    /// Live controllers for tabs torn off into their own windows, keyed by tab.
    private var detachedControllers: [BrowserTab.ID: DetachedTabWindowController] = [:]

    /// The tab currently being dragged from the sidebar, watched for a tear-off
    /// (drag released outside the main window).
    private var tearOffCandidate: BrowserTab.ID?
    private var tearOffTimer: Timer?

    /// Pop a tab out into its own chrome-less window. `screenPoint` (screen
    /// coordinates, bottom-left origin) positions the window; nil cascades off
    /// the main window. Re-popping an already-detached tab just focuses it.
    func popOutTab(_ id: BrowserTab.ID, at screenPoint: CGPoint? = nil) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isDetached {
            detachedControllers[id]?.focusWindow()
            return
        }
        tab.realize()

        let wasSelected = (selectedTabID == id)
        withAnimation(Motion.snappy) {
            for i in contexts.indices {
                contexts[i].tabIDs.removeAll { $0 == id }
                contexts[i].pinnedTabIDs.removeAll { $0 == id }
                for f in contexts[i].folders.indices {
                    contexts[i].folders[f].tabIDs.removeAll { $0 == id }
                }
            }
        }
        tab.isDetached = true

        if wasSelected {
            if id == splitTabID { splitTabID = nil }
            if let next = activeContext.tabIDs.first {
                selectTab(next)
            } else {
                selectedTabID = nil
            }
        }

        let size = detachedWindowSize()
        let point = screenPoint ?? detachedDefaultTopCenter(for: size)
        detachedControllers[id] = DetachedTabWindowController(
            tab: tab, store: self, topCenter: point, size: size)
        scheduleSessionSave()
    }

    /// Called by a detached window as it closes: tear the tab down for good.
    func detachedWindowDidClose(_ controller: DetachedTabWindowController) {
        let id = controller.tab.id
        controller.tab.isDetached = false
        closeTab(id, allowPinned: true, forceRemove: true)
        scheduleSessionSave()
        DispatchQueue.main.async { [weak self] in
            self?.detachedControllers[id] = nil
        }
    }

    /// Begin watching a sidebar tab drag: if the drag is released *outside* the
    /// main window, the tab tears off into its own window. Drags released inside
    /// the window (reorder / folder drops, or a miss) are left to SwiftUI.
    func beginTearOffWatch(for id: BrowserTab.ID) {
        tearOffCandidate = id
        tearOffTimer?.invalidate()
        let start = Date()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if NSEvent.pressedMouseButtons & 0x1 != 0 {
                if Date().timeIntervalSince(start) > 30 {
                    t.invalidate()
                    self.tearOffTimer = nil
                    self.tearOffCandidate = nil
                }
                return
            }
            t.invalidate()
            self.tearOffTimer = nil
            guard let candidate = self.tearOffCandidate else { return }
            self.tearOffCandidate = nil
            let p = NSEvent.mouseLocation
            if let frame = self.mainWindowFrame(), frame.contains(p) { return }
            self.popOutTab(candidate, at: p)
        }
        RunLoop.main.add(timer, forMode: .common)
        tearOffTimer = timer
    }

    /// Frame of the main Millie window — the one backed by a content view
    /// controller (detached / auxiliary windows use a plain content view).
    private func mainWindowFrame() -> NSRect? {
        NSApp.windows.first { $0.isVisible && $0.contentViewController != nil }?.frame
    }

    private func detachedWindowSize() -> NSSize {
        if let f = mainWindowFrame() {
            return NSSize(width: max(640, f.width * 0.7),
                          height: max(480, f.height * 0.85))
        }
        return NSSize(width: 1100, height: 760)
    }

    private func detachedDefaultTopCenter(for size: NSSize) -> CGPoint {
        if let f = mainWindowFrame() {
            return CGPoint(x: f.midX + 40, y: f.maxY - 40)
        }
        if let screen = NSScreen.main?.visibleFrame {
            return CGPoint(x: screen.midX, y: screen.midY + size.height / 2)
        }
        return CGPoint(x: 400, y: 800)
    }

    // MARK: - Contexts (Arc-style Spaces)

    /// Switch the sidebar (and chrome theme) to another context. Remembers the
    /// outgoing context's selection and restores the destination's last selected
    /// tab (or its first tab; an empty context just shows its New Tab
    /// affordances).
    func switchContext(to id: BrowserContext.ID, selectRemembered: Bool = true) {
        guard id != activeContextID,
              let targetIndex = contexts.firstIndex(where: { $0.id == id })
        else { return }

        // Stash the outgoing context's selection.
        if contexts.indices.contains(activeContextIndex) {
            contexts[activeContextIndex].selectedTabID = selectedTabID
        }

        // Slide direction: later Space → content slides in from the right.
        // Slower, bouncier spring (lower damping overshoots → more travel/bounce).
        contextSwitchForward = targetIndex >= activeContextIndex
        withAnimation(.spring(response: 0.55, dampingFraction: 0.58)) {
            activeContextID = id
        }
        settings.gradientTheme = themeForContext(contexts[targetIndex])

        if selectRemembered {
            let context = contexts[targetIndex]
            let candidate = context.selectedTabID.flatMap { sel in
                context.tabIDs.contains(sel) ? sel : nil
            } ?? context.tabIDs.first
            if let candidate {
                selectTab(candidate)
            }
        }
        syncActiveProfileToEngine()
        scheduleSessionSave()
    }

    /// Tell the engine which Profile is active so extension install/listing/
    /// management target it, then refresh the toolbar to that Profile's set.
    func syncActiveProfileToEngine() {
        MoriChromeExtensions.setActiveProfileKey(engineKey(for: activeContext))
        ExtensionStore.shared.refresh()
    }

    /// Switch to the context at a 1-based slot (Ctrl-1…Ctrl-9), following the
    /// bottom-bar switcher's order. Slots past the last context are ignored.
    func switchContext(atOrdinal ordinal: Int) {
        let index = ordinal - 1
        guard contexts.indices.contains(index) else { return }
        switchContext(to: contexts[index].id)
    }

    /// Cycle to the next (+1) / previous (-1) Space in switcher order, wrapping.
    func switchToAdjacentContext(_ delta: Int) {
        guard contexts.count > 1,
              let cur = contexts.firstIndex(where: { $0.id == activeContextID })
        else { return }
        let next = (cur + delta + contexts.count) % contexts.count
        switchContext(to: contexts[next].id)
    }

    /// Reorder a Space within the bottom-bar switcher.
    func moveContext(_ id: BrowserContext.ID, by delta: Int) {
        guard let from = contexts.firstIndex(where: { $0.id == id }) else { return }
        let to = from + delta
        guard contexts.indices.contains(to) else { return }
        withAnimation(Motion.snappy) { contexts.swapAt(from, to) }
        scheduleSessionSave()
    }

    /// Create a context and switch to it. Starts empty — the sidebar's New Tab
    /// affordances take it from there.
    @discardableResult
    func addContext(name: String, symbol: String, theme: GradientTheme = .none,
                    profileID: UUID? = nil) -> BrowserContext {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = BrowserContext(
            name: trimmed.isEmpty ? "Context \(contexts.count + 1)" : trimmed,
            symbol: symbol,
            theme: theme,
            profileID: profileID)
        withAnimation(Motion.snappy) { contexts.append(context) }
        switchContext(to: context.id)
        scheduleSessionSave()
        return context
    }

    /// Open Incognito: a private Space backed by the engine's off-the-record
    /// profile (no on-disk history, cookies, or cache; never persisted or
    /// synced). Reuses the open private Space if there is one. Wired to ⌘⇧N and
    /// the New-tab menu.
    func openPrivateWindow() {
        if let existing = contexts.first(where: { $0.isPrivate }) {
            if existing.id != activeContextID { switchContext(to: existing.id) }
            newTab()
            return
        }
        let context = BrowserContext(name: "Private",
                                     symbol: "eyeglasses",
                                     isPrivate: true)
        withAnimation(Motion.snappy) { contexts.append(context) }
        switchContext(to: context.id)
        newTab()
    }

    // MARK: - Remote sync merge (two-way)

    /// Tab/Space ids closed locally that the next push must tombstone in the
    /// cloud (`deleted=true`) so the deletion propagates to other devices
    /// instead of being resurrected by the union merge. Drained on push.
    private(set) var pendingTabTombstones: Set<UUID> = []
    private(set) var pendingSpaceTombstones: Set<UUID> = []

    /// Return and clear the queued tombstones (called by MillieSync on push).
    func drainTombstones() -> (tabs: [UUID], spaces: [UUID]) {
        defer { pendingTabTombstones.removeAll(); pendingSpaceTombstones.removeAll() }
        return (Array(pendingTabTombstones), Array(pendingSpaceTombstones))
    }

    /// A tab as it arrives from the cloud (decoded by MillieSync).
    struct RemoteTabRecord {
        let id: UUID
        let url: String
        let title: String
        let customTitle: String?
        let profileKey: String
        let faviconURL: String?
    }

    /// Merge a remote snapshot (Spaces/tabs/Profiles pulled from Supabase) into
    /// the live store. Non-destructive and engine-safe: remote tabs are added as
    /// *unrealized* (sleeping) tabs — nothing loads in Chromium until selected —
    /// and the active tab/selection is never touched. Union by id; remote wins on
    /// Space identity/structure; membership is merged (remote order, then any
    /// local-only ids). Mirrors the iOS `apply(_:)`.
    func applyRemoteSync(profiles remoteProfiles: [BrowserProfile],
                         spaces remoteSpaces: [BrowserContext],
                         tabs remoteTabs: [RemoteTabRecord],
                         deletedTabIDs: Set<UUID> = [],
                         deletedSpaceIDs: Set<UUID> = []) {
        // Profiles — add any missing (Default always exists locally).
        for p in remoteProfiles where p.id != BrowserProfile.defaultID
            && !profiles.contains(where: { $0.id == p.id }) {
            profiles.append(p)
        }

        // Ensure a sleeping tab exists for every remote record (skip tombstoned).
        let existing = Set(tabs.map(\.id))
        for rec in remoteTabs where !existing.contains(rec.id)
            && !deletedTabIDs.contains(rec.id) {
            let tab = makeTab(id: rec.id, url: rec.url, title: rec.title,
                              profileKey: rec.profileKey)
            tab.customTitle = rec.customTitle
            tab.faviconURL = rec.faviconURL
            tabs.append(tab)
        }
        // Quiet metadata refresh on existing tabs (never reloads them).
        for rec in remoteTabs {
            guard let tab = tabs.first(where: { $0.id == rec.id }) else { continue }
            if tab.title.isEmpty, !rec.title.isEmpty { tab.title = rec.title }
            if tab.faviconURL == nil { tab.faviconURL = rec.faviconURL }
            if let ct = rec.customTitle { tab.customTitle = ct }
        }

        // Apply remote tombstones: drop tabs deleted on another device, except
        // never touch incognito tabs (they're local-only).
        if !deletedTabIDs.isEmpty {
            for tab in tabs where deletedTabIDs.contains(tab.id) && tab.profileKey != "incognito" {
                if selectedTabID == tab.id { selectedTabID = nil }
                if splitTabID == tab.id { splitTabID = nil }
                tab.close()
            }
            tabs.removeAll { deletedTabIDs.contains($0.id) && $0.profileKey != "incognito" }
        }

        // Spaces — add new, merge membership for existing. Never disturb a
        // private (incognito) Space and never overwrite the local selection.
        for rs in remoteSpaces where !deletedSpaceIDs.contains(rs.id) {
            if let i = contexts.firstIndex(where: { $0.id == rs.id }) {
                guard !contexts[i].isPrivate else { continue }
                var c = contexts[i]
                c.name = rs.name; c.symbol = rs.symbol; c.theme = rs.theme
                c.profileID = rs.profileID
                c.tabIDs = mergedOrder(remote: rs.tabIDs, local: c.tabIDs)
                c.pinnedTabIDs = mergedOrder(remote: rs.pinnedTabIDs, local: c.pinnedTabIDs)
                if c.folders.isEmpty { c.folders = rs.folders }
                contexts[i] = c
            } else {
                contexts.append(rs)
            }
        }

        // Drop Spaces tombstoned elsewhere, and scrub deleted tab ids from every
        // remaining Space's membership so they don't linger in the sidebar.
        if !deletedSpaceIDs.isEmpty {
            contexts.removeAll { deletedSpaceIDs.contains($0.id) && !$0.isPrivate }
        }
        if !deletedTabIDs.isEmpty {
            for i in contexts.indices {
                contexts[i].tabIDs.removeAll { deletedTabIDs.contains($0) }
                contexts[i].pinnedTabIDs.removeAll { deletedTabIDs.contains($0) }
                for f in contexts[i].folders.indices {
                    contexts[i].folders[f].tabIDs.removeAll { deletedTabIDs.contains($0) }
                }
                if let sel = contexts[i].selectedTabID, deletedTabIDs.contains(sel) {
                    contexts[i].selectedTabID = nil
                }
            }
        }

        ensureContextIntegrity()
        // If the active selection got tombstoned away, pick a sensible neighbour.
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            if let first = activeContext.tabIDs.first(where: { id in tabs.contains { $0.id == id } }) {
                selectTab(first)
            }
        }
        scheduleSessionSave()
    }

    /// Union of two id lists: remote order first, then any local-only ids.
    private func mergedOrder(remote: [UUID], local: [UUID]) -> [UUID] {
        var seen = Set(remote)
        var result = remote
        for id in local where !seen.contains(id) { result.append(id); seen.insert(id) }
        return result
    }

    // MARK: Profiles (Arc-style isolation identities)

    /// Create a new Profile (its own persistent Chromium profile is created
    /// lazily by the engine the first time a tab uses it).
    @discardableResult
    func addProfile(name: String, symbol: String = "glyph-circle") -> BrowserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = BrowserProfile(
            name: trimmed.isEmpty ? "Profile \(profiles.count)" : trimmed,
            symbol: symbol)
        profiles.append(profile)
        scheduleSessionSave()
        return profile
    }

    func renameProfile(_ id: BrowserProfile.ID, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { profiles[idx].name = trimmed }
        scheduleSessionSave()
    }

    /// Reorder a Profile in the Settings list.
    func moveProfile(_ id: BrowserProfile.ID, by delta: Int) {
        guard let from = profiles.firstIndex(where: { $0.id == id }) else { return }
        let to = from + delta
        guard profiles.indices.contains(to) else { return }
        profiles.swapAt(from, to)
        scheduleSessionSave()
    }

    /// Assign a Space to a Profile and re-home its existing tabs into it. A
    /// tab's cookie jar is fixed when its engine tab is created, so live tabs
    /// are rebuilt (they reload in the new Profile); the visible tab reloads
    /// immediately, background tabs on next view.
    func setProfile(_ profileID: UUID, forContext contextID: BrowserContext.ID) {
        guard let idx = contexts.firstIndex(where: { $0.id == contextID }) else { return }
        contexts[idx].profileID = profileID
        let key = (profiles.first { $0.id == profileID } ?? .default).profileKey
        rehomeTabs(inContext: contextID, toKey: key)
        scheduleSessionSave()
    }

    /// Move every tab in a Space onto `key`, rebuilding any realized engine tab
    /// so storage actually switches Profiles. Only re-realizes the visible tab
    /// when the Space is active (avoids yanking focus to a background Space).
    private func rehomeTabs(inContext contextID: BrowserContext.ID, toKey key: String) {
        guard let ctx = contexts.first(where: { $0.id == contextID }) else { return }
        let memberIDs = Set(ctx.tabIDs)
        for tab in tabs where memberIDs.contains(tab.id) && tab.profileKey != key {
            tab.profileKey = key
            if tab.hasRealized { tab.sleep() }
        }
        if contextID == activeContextID, let sel = selectedTabID,
           memberIDs.contains(sel) {
            selectTab(sel)
        }
    }

    /// Delete a Profile. The built-in Default can't be removed; Spaces using the
    /// removed profile fall back to Default (and their tabs re-home to it).
    func deleteProfile(_ id: BrowserProfile.ID) {
        guard id != BrowserProfile.defaultID,
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: idx)
        for i in contexts.indices where contexts[i].profileID == id {
            contexts[i].profileID = BrowserProfile.defaultID
            rehomeTabs(inContext: contexts[i].id, toKey: "default")
        }
        scheduleSessionSave()
    }

    /// Delete a context, closing its tabs. The last context can't be deleted —
    /// matching Arc, there is always at least one space.
    func deleteContext(_ id: BrowserContext.ID) {
        guard contexts.count > 1,
              let idx = contexts.firstIndex(where: { $0.id == id })
        else { return }

        if id == activeContextID {
            let fallback = contexts[idx == 0 ? 1 : idx - 1].id
            switchContext(to: fallback)
        }
        let doomedTabs = contexts[idx].tabIDs
        pendingSpaceTombstones.insert(id)   // propagate the Space deletion
        RouteStore.shared.removeRules(forContext: id)
        withAnimation(Motion.snappy) {
            contexts.removeAll { $0.id == id }
        }
        for tabID in doomedTabs {
            closeTab(tabID, allowPinned: true)
        }
        scheduleSessionSave()
    }

    func renameContext(_ id: BrowserContext.ID, to name: String) {
        guard let idx = contexts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        contexts[idx].name = trimmed
        scheduleSessionSave()
    }

    func setContextSymbol(_ id: BrowserContext.ID, symbol: String) {
        guard let idx = contexts.firstIndex(where: { $0.id == id }) else { return }
        contexts[idx].symbol = symbol
        scheduleSessionSave()
    }

    func setContextTheme(_ id: BrowserContext.ID, theme: GradientTheme) {
        // Themes live on the Profile now; editing a Space edits its Profile's
        // theme (shared by every Space on that Profile).
        guard let ctx = contexts.first(where: { $0.id == id }) else { return }
        setProfileTheme(ctx.profileID ?? BrowserProfile.defaultID, theme: theme)
    }

    // MARK: Per-Profile theming

    /// The gradient theme in effect for a Space — its Profile's theme.
    func themeForContext(_ ctx: BrowserContext) -> GradientTheme {
        profileTheme(ctx.profileID ?? BrowserProfile.defaultID)
    }

    /// A Profile's theme (`.none` if the Profile is unknown/unthemed).
    func profileTheme(_ profileID: BrowserProfile.ID) -> GradientTheme {
        profiles.first { $0.id == profileID }?.theme ?? .none
    }

    /// Set a Profile's theme: update the Profile, mirror it onto every Space
    /// using that Profile (keeps `context.theme` a live cache for the switch/
    /// mirror machinery), and apply it live if that Profile is active.
    func setProfileTheme(_ profileID: BrowserProfile.ID, theme: GradientTheme) {
        applyThemeToProfile(profileID, theme)
        if (activeContext.profileID ?? BrowserProfile.defaultID) == profileID {
            settings.gradientTheme = theme
        }
    }

    private func applyThemeToProfile(_ profileID: BrowserProfile.ID, _ theme: GradientTheme) {
        if let pi = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[pi].theme = theme
        }
        for i in contexts.indices
        where (contexts[i].profileID ?? BrowserProfile.defaultID) == profileID {
            contexts[i].theme = theme
        }
        scheduleSessionSave()
    }

    /// Open a fresh tab side-by-side with the current one (the plus menu's
    /// "New Split"). The new tab joins the sidebar like any other.
    func newSplit() {
        guard selectedTab != nil else {
            newTab()
            return
        }
        let tab = newTab(select: false)
        splitWith(tab.id, side: .right)
    }
}

/// Normalizes URLs before a tab is ever created. Chrome's own schemes
/// (including chrome-extension://) load natively, so this is currently a
/// pass-through kept for the call-site shape.
enum MoriURLRewriter {
    static func rewrite(_ raw: String) -> String { raw }
}

/// Source-specific navigation policy. Omnibox/user-entered URLs may still use
/// Millie/Chromium internal schemes, but page-derived and assistant-proposed
/// navigation should treat them as privileged and disclose that before loading.
enum BrowserURLPolicy {
    private static let webSchemes: Set<String> = ["http", "https"]
    private static let privilegedSchemes: Set<String> = [
        "file", "millie", "mori", "chrome", "chrome-extension"
    ]

    static func isWebURL(_ raw: String) -> Bool {
        guard let scheme = scheme(of: raw) else { return false }
        return webSchemes.contains(scheme)
    }

    static func isPrivilegedURL(_ raw: String) -> Bool {
        guard let scheme = scheme(of: raw) else { return false }
        return privilegedSchemes.contains(scheme)
    }

    static func explicitURL(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, scheme(of: text) != nil else { return nil }
        return MoriURLRewriter.rewrite(text)
    }

    static func scheme(of raw: String) -> String? {
        URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?
            .scheme?
            .lowercased()
    }

    static func schemeLabel(for raw: String) -> String {
        scheme(of: raw).map { "\($0)://" } ?? "this"
    }
}

extension BrowserStore {
    func confirmPrivilegedNavigation(_ url: String, source: String) -> Bool {
        guard BrowserURLPolicy.isPrivilegedURL(url) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open Internal or Local URL?"
        alert.informativeText = """
        \(source) wants to open \(BrowserURLPolicy.schemeLabel(for: url)) content:

        \(url)

        Only continue if you expected this navigation.
        """
        alert.addButton(withTitle: "Open URL")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func resolvePageDerivedNavigationURL(_ rawURL: String, source: String) -> String? {
        guard let url = BrowserURLPolicy.explicitURL(rawURL) else {
            ToastCenter.shared.show("Blocked invalid link", icon: "link", style: .warning)
            return nil
        }
        if BrowserURLPolicy.isWebURL(url) { return url }
        guard BrowserURLPolicy.isPrivilegedURL(url),
              confirmPrivilegedNavigation(url, source: source) else {
            ToastCenter.shared.show("Blocked non-web link", icon: "lock", style: .warning)
            return nil
        }
        return url
    }
}

/// Turns omnibox input into a navigable URL or a search, honoring the user's
/// configured homepage and default search engine.
enum URLInterpreter {
    private static let allowedSchemes: Set<String> = [
        "http", "https", "file", "about", "millie", "mori", "chrome",
        "chrome-extension"
    ]

    static func resolve(_ raw: String, settings: BrowserSettings) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return settings.homepageURL }

        // Already has a scheme.
        if hasAllowedScheme(text) {
            return text
        }

        // Looks like an address without a scheme, including paths, ports,
        // localhost, IPv4, and bracketed IPv6 hosts. Local addresses default
        // to http since they rarely serve TLS.
        if looksLikeWebAddress(text) {
            return "\(defaultScheme(forAddress: text))://\(text)"
        }

        // Otherwise search with the configured engine.
        return settings.searchURL(for: text)
    }

    static func resolvesAsAddress(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return hasAllowedScheme(text) || looksLikeWebAddress(text)
    }

    private static func hasAllowedScheme(_ text: String) -> Bool {
        guard let scheme = URLComponents(string: text)?.scheme?.lowercased() else {
            return false
        }
        return allowedSchemes.contains(scheme)
    }

    private static func looksLikeWebAddress(_ text: String) -> Bool {
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              !text.contains("://")
        else {
            return false
        }

        let authority = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? ""
        guard !authority.isEmpty else { return false }

        if authority.lowercased() == "localhost" {
            return true
        }
        if authority.lowercased().hasPrefix("localhost:") {
            let port = String(authority.dropFirst("localhost:".count))
            return isValidPort(port)
        }

        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return false }
            let host = String(authority[authority.index(after: authority.startIndex)..<end])
            let suffix = authority[authority.index(after: end)...]
            guard suffix.isEmpty || suffix.first == ":" else { return false }
            if suffix.first == ":" {
                let port = String(suffix.dropFirst())
                guard isValidPort(port) else { return false }
            }
            return isIPv6Literal(host)
        }

        let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, !isValidPort(String(parts[1])) {
            return false
        }

        let host = parts.first.map(String.init) ?? ""
        guard !host.isEmpty else { return false }

        if isIPv4Literal(host) { return true }
        return isDomainName(host)
    }

    /// Picks the implicit scheme for a scheme-less address. Local addresses
    /// (localhost, *.localhost, loopback IPs) use http; everything else https.
    private static func defaultScheme(forAddress text: String) -> String {
        let authority = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? ""
        let host: String
        if authority.hasPrefix("["), let end = authority.firstIndex(of: "]") {
            host = String(authority[authority.index(after: authority.startIndex)..<end])
        } else {
            host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
        }
        return isLocalHost(host) ? "http" : "https"
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") { return true }
        if lower == "::1" { return true }
        if isIPv4Literal(lower) { return lower.hasPrefix("127.") }
        return false
    }

    private static func isDomainName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }),
              let tld = labels.last,
              tld.count >= 2,
              tld.rangeOfCharacter(from: .letters) != nil
        else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.allSatisfy { label in
            guard label.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
            return !(label.hasPrefix("-") || label.hasSuffix("-"))
        }
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == part || part == "0"
        }
    }

    private static func isValidPort(_ raw: String) -> Bool {
        guard let port = Int(raw), (0...65535).contains(port) else {
            return false
        }
        return String(port) == raw || raw == "0"
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_INET6,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        defer {
            if let result { freeaddrinfo(result) }
        }
        return getaddrinfo(host, nil, &hints, &result) == 0
    }
}
