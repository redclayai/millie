import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The vertical sidebar — Arc/SigmaOS-inspired. Top-to-bottom:
/// a header carrying the browser controls (nav + omnibox + downloads), a
/// pinned-tab tile grid, collapsible folders, the loose (unfiled) tabs under a
/// New Tab row, and a bottom action bar. Translucent glass over the Millie
/// `--sidebar-*` tokens.
struct Sidebar: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared

    /// True when hosted as a standalone floating card (the peek overlay) rather
    /// than docked. In that mode there's no adjacent web-card float gap to
    /// compensate for, so the row/header padding stays symmetric instead of
    /// trimming the web-card-facing edge.
    var floating: Bool = false

    /// The tab currently being dragged in the sidebar, shared across all drop
    /// targets so any container can reorder/accept it live. Held here at the top
    /// level and threaded down as a binding.
    @State private var draggingTabID: BrowserTab.ID?

    /// Live width while the resize handle is being dragged. Kept local so each
    /// drag frame is a cheap in-view update — the persisted (and UserDefaults-
    /// backed) `settings.sidebarWidth` is only written once, on release.
    @State private var liveWidth: CGFloat?

    /// The web card floats with an 8pt gap on its sidebar-facing edge. Trim the
    /// row padding by that gap on the same side so tab cards sit evenly inset
    /// within the visible chrome instead of crowding the outer window edge.
    private static let webCardGap: CGFloat = 8
    private func rowInsets(_ base: CGFloat) -> EdgeInsets {
        if floating {
            return EdgeInsets(top: 0, leading: base, bottom: 0, trailing: base)
        }
        let trimLeading = settings.sidebarPosition == .right
        return EdgeInsets(
            top: 0,
            leading: base - (trimLeading ? Self.webCardGap : 0),
            bottom: 0,
            trailing: base - (trimLeading ? 0 : Self.webCardGap)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.contextCreationVisible {
                CreateContextView(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if let tab = store.selectedTab ?? store.tabs.first {
                    SidebarHeader(store: store, tab: tab, floating: floating)
                        .zIndex(10)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ContextHeaderRow(store: store)
                            .padding(rowInsets(8))
                            .padding(.top, 4)

                        if !store.pinnedTabs.isEmpty || draggingTabID != nil {
                            PinnedGrid(store: store, draggingTabID: $draggingTabID)
                                .padding(rowInsets(8))
                        }

                        if store.folders.contains(where: { !$0.isTidy }) {
                            FolderSection(store: store, draggingTabID: $draggingTabID)
                                .padding(rowInsets(8))
                            // While a drag is up, an explicit "leave the folders"
                            // target: dropping here places the tab loose (top of
                            // the list) — the visible way to un-folder by drag.
                            if draggingTabID != nil {
                                UnfolderDropZone(store: store,
                                                 draggingTabID: $draggingTabID)
                                    .padding(rowInsets(8))
                            }
                            SidebarSeparator()
                                .padding(rowInsets(8))
                        }

                        // Tidy groups sit BELOW the folders line: temporary,
                        // distinct from permanent folders.
                        if store.folders.contains(where: { $0.isTidy }) {
                            TidySection(store: store, draggingTabID: $draggingTabID)
                                .padding(rowInsets(8))
                            SidebarSeparator()
                                .padding(rowInsets(8))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            NewTabRow { store.presentLauncher() }
                                .onDrop(of: SidebarTabDrag.acceptedTypes,
                                        delegate: TabReorderDropDelegate(
                                            target: .loose(index: 0),
                                            draggingID: $draggingTabID,
                                            store: store))
                            LooseTabList(store: store, draggingTabID: $draggingTabID)
                        }
                            .padding(rowInsets(8))
                            .padding(.bottom, 10)
                    }
                    .padding(.top, 2)
                    // Re-identify the tab list per context so a Space switch
                    // slides the whole list horizontally (clipped to the
                    // ScrollView) — new Space in from one edge, old out the
                    // other, following the switch direction.
                    .id(store.activeContextID)
                    .transition(.asymmetric(
                        insertion: .move(edge: store.contextSwitchForward ? .trailing : .leading)
                            .combined(with: .opacity),
                        removal: .move(edge: store.contextSwitchForward ? .leading : .trailing)
                            .combined(with: .opacity)))
                }
                .clipped()
                SidebarMediaSection(store: store, media: store.media)
            }
            SidebarBottomBar(store: store)
        }
        .animation(Motion.reveal, value: store.contextCreationVisible)
        .frame(width: liveWidth ?? settings.sidebarWidth)
        .contentShape(Rectangle())
        // Two-finger horizontal swipe over the sidebar switches Spaces (Arc/Dia).
        .background(SpaceSwipeCatcher { store.switchToAdjacentContext($0) })
        .contextMenu { SidebarContextMenu(store: store) }
        .onDrop(of: SidebarTabDrag.acceptedTypes,
                delegate: TabReorderDropDelegate(
                    target: .loose(index: store.looseTabs.count),
                    draggingID: $draggingTabID,
                    store: store,
                    moveOnEnter: false))
        // Resize handle on the inner (web-card-facing) edge: leading when the
        // sidebar sits on the right, trailing when it sits on the left.
        .overlay(alignment: settings.sidebarPosition == .right ? .leading : .trailing) {
            SidebarResizeHandle(store: store, position: settings.sidebarPosition,
                                liveWidth: $liveWidth)
        }
        // No own background: the unified chrome surface (set on the root) shows
        // through, so the sidebar and the card's inset gaps are the same color.
    }
}

/// A thin, draggable strip along the sidebar's inner edge that resizes it.
/// Shows a faint divider on hover (hidden while dragging) and a resize cursor.
/// During the drag it only updates the parent's cheap `liveWidth` state;
/// the persisted `settings.sidebarWidth` is written once, on release.
private struct SidebarResizeHandle: View {
    @ObservedObject var store: BrowserStore
    let position: SidebarPosition
    @Binding var liveWidth: CGFloat?
    @ObservedObject private var settings = BrowserSettings.shared
    @State private var dragStartWidth: CGFloat?

    private static let hitWidth: CGFloat = 8

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.hitWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? settings.sidebarWidth
                        if dragStartWidth == nil {
                            dragStartWidth = start
                            store.isResizingSidebar = true
                        }
                        // Right sidebar grows when dragged left (negative dx);
                        // left sidebar grows when dragged right (positive dx).
                        let delta = position == .right ? -value.translation.width
                                                       : value.translation.width
                        liveWidth = (start + delta).clamped(
                            to: BrowserSettings.minSidebarWidth...BrowserSettings.maxSidebarWidth)
                    }
                    .onEnded { _ in
                        if let final = liveWidth { settings.sidebarWidth = final }
                        dragStartWidth = nil
                        liveWidth = nil
                        // Unfreeze the web card; the CEF view resizes once now.
                        store.isResizingSidebar = false
                    }
            )
    }
}

/// General right-click menu for the sidebar background and non-row chrome.
private struct SidebarContextMenu: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        Button("New Tab") {
            store.newTab()
        }
        Button("Reopen Closed Tab") {
            store.reopenClosedTab()
        }
        .disabled(!store.canReopenClosedTab)
        Button("Add New Folder") {
            store.addFolderForEditing()
        }
        Button("Tidy Tabs") {
            store.tidyTabs()
        }

        Divider()

        Button("Sleep Background Tabs") {
            store.sleepBackgroundTabs()
        }
        Button("Peek a Link") {
            store.peekFromClipboardOrCurrent()
        }
        Button("Capture Region…") {
            store.startRegionCapture()
        }
        Button("Capture Visible Tab") {
            store.captureVisibleArea()
        }

        Divider()

        if settings.aiIntegrationEnabled {
            Button(store.aiPanelVisible ? "Hide AI Panel" : "Show AI Panel") {
                store.toggleAIPanel()
            }
        }
        Menu("Sidebar Side") {
            ForEach(SidebarPosition.allCases) { position in
                Button(position.label) {
                    settings.sidebarPosition = position
                }
            }
        }
        Button("Hide Sidebar") {
            store.toggleSidebar()
        }

        Divider()

        Button("Settings") {
            store.settingsVisible = true
        }
    }
}

/// Observes the media controller so the player strip appears only for playback
/// happening outside the current tab.
private struct SidebarMediaSection: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var media: MediaController

    var body: some View {
        if shouldShowMedia {
            MediaPlayerStrip(store: store, media: media)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.reveal, value: shouldShowMedia)
        }
    }

    private var shouldShowMedia: Bool {
        guard media.hasMedia else { return false }
        guard let owningTab = media.resolveTab?(media.state.browserId) else {
            return true
        }
        return owningTab.id != store.selectedTabID
    }
}

// MARK: - Header (relocated browser chrome)

/// The sidebar's top section now hosts the browser controls that used to live in
/// the top toolbar: the sidebar toggle, back / forward / reload, and the
/// omnibox. The nav row carries the toggle on the left and the nav buttons on
/// the right, with the full-width address field below, à la Arc/Dia.
private struct SidebarHeader: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var settings = BrowserSettings.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var showDownloads = false
    var floating: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                IconButton(systemName: settings.sidebarPosition.symbol, size: 28) {
                    store.toggleSidebar()
                }
                    .help("Toggle sidebar")
                Spacer()
                IconButton(systemName: "arrow.backward", size: 28,
                           disabled: !tab.canGoBack,
                           help: "Back") { store.goBack() }
                IconButton(systemName: "arrow.forward", size: 28,
                           disabled: !tab.canGoForward,
                           help: "Forward") { store.goForward() }
                IconButton(systemName: tab.isLoading ? "xmark" : "arrow.clockwise",
                           size: 28,
                           help: tab.isLoading ? "Stop" : "Reload") {
                    tab.isLoading ? store.stop() : store.reload()
                }
                DownloadsButton(downloads: downloads, isOpen: $showDownloads)
            }

            Omnibox(store: store, tab: tab)
                .frame(maxWidth: .infinity)

            if store.activeContext.isPrivate {
                PrivateBanner()
            }
        }
        // Mirror the tab rows: trim the padding on the web-card-facing edge by
        // its 8pt float gap so the header reads as evenly inset, not crowded
        // toward the outer window edge. When floating (peek), there's no gap to
        // compensate for, so keep the inset symmetric.
        .padding(.leading, floating ? 10 : (settings.sidebarPosition == .right ? 2 : 10))
        .padding(.trailing, floating ? 10 : (settings.sidebarPosition == .right ? 10 : 2))
        // Reserve the macOS traffic-light strip (~28pt) when the sidebar is on
        // the left, so the toggle/nav row clears the window controls. A floating
        // peek panel and a right-side sidebar don't sit under the controls.
        .padding(.top, (!floating && settings.sidebarPosition == .left) ? 32 : 10)
        .padding(.bottom, 6)
    }
}

private struct SidebarSeparator: View {
    @Environment(\.palette) private var p

    var body: some View {
        Rectangle()
            .fill(p.sidebarForeground.color.opacity(0.12))
            .frame(height: 1)
    }
}

/// A slim incognito notice shown under the omnibox while a private Space is
/// active — the clear "you're browsing privately" signal.
private struct PrivateBanner: View {
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: "eyeglasses", size: 13)
                .foregroundStyle(p.foreground.color.opacity(0.9))
            Text("Private — history isn't saved")
                .font(Typography.ui(Typography.label, weight: .medium))
                .foregroundStyle(p.foreground.color.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .fill(p.foreground.color.opacity(0.08))
        )
    }
}

// MARK: - Pinned tiles

private struct PinnedGrid: View {
    @ObservedObject var store: BrowserStore
    @Binding var draggingTabID: BrowserTab.ID?
    @State private var dropTargeted = false

    /// Pinned tiles lay out at most 3 per row, widening to 4 only once there are
    /// 4+ pins. Flexible columns split the available sidebar width evenly, so the
    /// tiles grow and shrink as the sidebar is resized. While empty (a drag is in
    /// progress) a single column keeps the drop hint full-width.
    private var columns: [GridItem] {
        let count = store.pinnedTabs.isEmpty
            ? 1
            : (store.pinnedTabs.count >= 4 ? 4 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            if store.pinnedTabs.isEmpty {
                SidebarDropCatchZone(height: 40,
                                     cornerRadius: TabSurface.radius,
                                     isTargeted: dropTargeted)
            }

            ForEach(Array(store.pinnedTabs.enumerated()), id: \.element.id) { idx, tab in
                PinnedTile(
                    tab: tab,
                    isSelected: tab.id == store.selectedTabID,
                    onSelect: { store.selectTab(tab.id) }
                )
                .contextMenu { TabMenu(store: store, tab: tab) }
                .onDrag {
                    draggingTabID = tab.id
                    store.beginTearOffWatch(for: tab.id)
                    return SidebarTabDrag.provider(for: tab.id)
                } preview: {
                    // Hide the cursor-following drag image: the live row already
                    // reorders in place, so a second floating copy under the
                    // pointer just reads as a confusing duplicate.
                    Color.clear.frame(width: 1, height: 1)
                }
                .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
                    target: .pinned(index: idx),
                    draggingID: $draggingTabID,
                    store: store))
            }
        }
        // Catch-all: dropping anywhere in the grid appends to the pins.
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
            target: .pinned(index: store.pinnedTabs.count),
            draggingID: $draggingTabID,
            store: store,
            isTargeted: $dropTargeted))
    }
}

private struct PinnedTile: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        Favicon(icon: tab.faviconURL, page: tab.urlString, image: tab.faviconImage,
                size: 24, active: !tab.isAsleep)
            .grayscale(tab.isAsleep ? 1 : 0)
            .opacity(tab.isAsleep ? 0.5 : 1)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: TabSurface.radius, style: .continuous)
                    .fill(tileFill)
                    .shadow(color: isSelected ? TabSurface.shadow(scheme) : .clear,
                            radius: isSelected ? TabSurface.shadowRadius : 0,
                            x: 0, y: isSelected ? TabSurface.shadowY : 0)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            )
            .contentShape(Rectangle())
            .pressShrink(perform: onSelect) { isPressing in
                pressing = isPressing
            }
            .onHover { hovering = $0 }
            .help(tab.displayTitle)
    }

    private var tileFill: Color {
        if isSelected || pressing { return TabSurface.selectedFill(scheme) }
        if hovering { return TabSurface.hoverFill(scheme) }
        return TabSurface.tileRestFill(scheme)
    }
}

// MARK: - Folders

private struct FolderSection: View {
    @ObservedObject var store: BrowserStore
    @Binding var draggingTabID: BrowserTab.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Permanent, user-made folders only. Tidy groups render separately
            // in TidySection, below the folders separator.
            ForEach(store.folders.filter { !$0.isTidy }) { folder in
                FolderRow(store: store, folder: folder, draggingTabID: $draggingTabID)
            }
        }
    }
}

/// The "Tidy Tabs" result: temporary auto-groups, shown below the folders
/// separator with a quiet header and a Clear action — kept visually distinct
/// from permanent folders (a different feature).
private struct TidySection: View {
    @ObservedObject var store: BrowserStore
    @Binding var draggingTabID: BrowserTab.ID?
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("TIDIED")
                    .font(Typography.ui(Typography.caption, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(p.mutedForeground.color.opacity(0.85))
                Spacer(minLength: 0)
                Button("Clear") { store.clearTidyGroups() }
                    .buttonStyle(.plain)
                    .font(Typography.ui(Typography.caption, weight: .medium))
                    .foregroundStyle(p.primary.color)
                    .help("Ungroup — return these tabs to the list")
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 2)
            ForEach(store.folders.filter { $0.isTidy }) { folder in
                FolderRow(store: store, folder: folder, draggingTabID: $draggingTabID)
            }
        }
    }
}

private struct FolderRow: View {
    @ObservedObject var store: BrowserStore
    let folder: TabFolder
    @Binding var draggingTabID: BrowserTab.ID?

    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var settings = BrowserSettings.shared
    @State private var hovering = false
    @State private var headerDropTargeted = false
    @State private var isEditing = false
    @State private var draftName = ""
    @State private var showIconPicker = false
    @State private var splitDropTargetID: BrowserTab.ID?
    @FocusState private var nameFocused: Bool

    private var childTabs: [BrowserTab] { store.tabs(in: folder) }

    private var containsActiveTab: Bool {
        childTabs.contains { $0.id == store.selectedTabID }
    }

    /// Tab whose favicon represents the folder. Prefer a child with a decoded
    /// favicon image (renders a real site glyph), then any with a favicon URL,
    /// then the first child. Drives the folder's site-icon glyph.
    private var representativeTab: BrowserTab? {
        childTabs.first { $0.faviconImage != nil }
            ?? childTabs.first { $0.faviconURL != nil }
            ?? childTabs.first
    }

    /// The folder's accent: the user-picked color, else the dominant color of
    /// the representative tab's favicon, else nil (default chrome colors).
    /// Restored/unrealized tabs have no live `faviconImage`, so fall back to the
    /// persistent favicon cache (memory + disk, keyed by host) — that's what
    /// keeps Jira blue / Grafana orange across restarts.
    private var folderTint: Color? {
        if folder.colorHex == TabFolder.noColor { return nil }
        if let hex = folder.colorHex { return TokenColor(hex: hex).color }
        let image = representativeTab?.faviconImage
            ?? FaviconCache.shared.cached(
                host: SiteBrand.host(from: representativeTab?.urlString))
        if let image, let dominant = FaviconDominantColor.color(for: image) {
            return Color(nsColor: dominant)
        }
        return nil
    }

    /// The card wash is off when the user disabled it globally (Settings) or
    /// chose "No Color" for this folder.
    private var showsCard: Bool {
        settings.tintedFolderCards && folder.colorHex != TabFolder.noColor
    }

    /// The palette offered in the folder's Color menu (mirrors Dia's row).
    static let colorChoices: [(name: String, hex: String)] = [
        ("Black", "#1C1C1E"), ("Green", "#34A853"), ("Blue", "#3E6AE1"),
        ("Purple", "#6E56CF"), ("Yellow", "#EAB308"), ("Pink", "#EC4899"),
        ("Red", "#EF4444"), ("Orange", "#F97316"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Folder header row.
            HStack(spacing: 8) {
                if folder.isTidy {
                    // Tidy group: a distinct grouping glyph (NOT the folder
                    // icon) — this is a temporary auto-group, a different
                    // feature from folders. No icon picker.
                    Icon(name: "rectangle.3.group", size: 15)
                        .foregroundStyle(folderTint ?? p.mutedForeground.color)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                } else {
                    MorphingFolderIcon(
                        isOpen: folder.isExpanded,
                        showsDots: !folder.isExpanded && containsActiveTab,
                        symbol: folder.symbol,
                        faviconIcon: representativeTab?.faviconURL,
                        faviconPage: representativeTab?.urlString,
                        faviconImage: representativeTab?.faviconImage,
                        size: 24,
                        frontColor: (folderTint ?? p.primary.color).opacity(folderTint == nil ? 0.18 : 0.30),
                        backColor: (folderTint ?? p.primary.color).opacity(folderTint == nil ? 0.32 : 0.55),
                        stroke: (folderTint ?? p.sidebarForeground.color).opacity(0.55),
                        glyphColor: p.sidebarForeground.color.opacity(0.85),
                        surface: p.sidebar.color
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    // Clicking the folder icon itself opens the icon picker
                    // (Arc behavior); the rest of the row still toggles.
                    .onTapGesture { showIconPicker = true }
                    .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                        FolderIconPicker(store: store, folder: folder,
                                         isPresented: $showIconPicker)
                            .environment(\.palette, p)
                    }
                }

                if isEditing {
                    TextField("Folder", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.sidebarForeground.color)
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } else {
                    Text(folder.name)
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.sidebarForeground.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill((hovering || headerDropTargeted) ? p.foreground.color.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { if !isEditing { store.toggleFolder(folder.id) } }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Rename") { beginRename() }
                if !folder.isTidy {
                    Button("Change Icon…") { showIconPicker = true }
                }
                Menu("Color") {
                    Button {
                        store.setFolderColor(folder.id, hex: nil)
                    } label: {
                        if folder.colorHex == nil {
                            Label("From Tab Icon", systemImage: "checkmark")
                        } else {
                            Text("From Tab Icon")
                        }
                    }
                    Button {
                        store.setFolderColor(folder.id, hex: TabFolder.noColor)
                    } label: {
                        if folder.colorHex == TabFolder.noColor {
                            Label("No Color", systemImage: "checkmark")
                        } else {
                            Text("No Color")
                        }
                    }
                    Divider()
                    ForEach(FolderRow.colorChoices, id: \.hex) { choice in
                        Button {
                            store.setFolderColor(folder.id, hex: choice.hex)
                        } label: {
                            if folder.colorHex == choice.hex {
                                Label(choice.name, systemImage: "checkmark")
                            } else {
                                Text(choice.name)
                            }
                        }
                    }
                }
                Button("New Tab in Folder") {
                    let tab = store.newTab()
                    store.addTab(tab.id, toFolder: folder.id)
                }
                Divider()
                Button("Separate Tabs") { store.separateFolderTabs(folder.id) }
                Button("Duplicate") { store.duplicateFolder(folder.id) }
                Button("Copy All Links as Markdown") { store.copyFolderLinksAsMarkdown(folder.id) }
                Divider()
                Button("Close Folder & Tabs", role: .destructive) {
                    store.closeFolderAndTabs(folder.id)
                }
            }
            // Dropping onto the header appends the tab and expands the folder.
            .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
                target: .folder(id: folder.id, index: Int.max),
                draggingID: $draggingTabID,
                store: store,
                isTargeted: $headerDropTargeted))

            // Nested tabs.
            if folder.isExpanded {
                ForEach(Array(childTabs.enumerated()), id: \.element.id) { idx, tab in
                    TabRow(
                        tab: tab,
                        store: store,
                        isSelected: tab.id == store.selectedTabID,
                        onSelect: { store.selectTab(tab.id) },
                        onClose: { store.closeTab(tab.id, allowFolderRemoval: true) },
                        onIconTap: { store.resetFolderedTabToHome(tab.id) }
                    )
                    .padding(.leading, 16)
                    .transition(.tabClose)
                    .overlay {
                        if splitDropTargetID == tab.id {
                            RoundedRectangle(cornerRadius: TabSurface.radius, style: .continuous)
                                .strokeBorder(p.primary.color, lineWidth: 2)
                                .padding(.leading, 16)
                        }
                    }
                    .contextMenu { TabMenu(store: store, tab: tab) }
                    .onDrag {
                        draggingTabID = tab.id
                        store.beginTearOffWatch(for: tab.id)
                        return SidebarTabDrag.provider(for: tab.id)
                    } preview: {
                        // Hide the cursor-following drag image: the live row
                        // already reorders in place, so a second floating copy
                        // under the pointer just reads as a confusing duplicate.
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
                        target: .folder(id: folder.id, index: idx),
                        draggingID: $draggingTabID,
                        store: store,
                        splitTargetID: tab.id,
                        splitHover: $splitDropTargetID))
                }
            }
        }
        // Dia-style group card: the whole block (header + tabs) sits on a wash
        // of the folder's accent color — favicon-derived by default, or the
        // user's pick from the Color menu.
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg + 2, style: .continuous)
                .fill(showsCard ? (folderTint ?? p.primary.color).opacity(cardOpacity)
                                : .clear)
        )
        .onAppear(perform: beginRenameIfRequested)
        .onChange(of: store.folderIDPendingRename) { _, _ in
            beginRenameIfRequested()
        }
    }

    /// Subtle in light mode, a touch stronger in dark so the wash still reads.
    private var cardOpacity: Double { scheme == .dark ? 0.24 : 0.16 }

    private func beginRenameIfRequested() {
        guard store.folderIDPendingRename == folder.id else { return }
        beginRename()
        store.consumeFolderRenameRequest(for: folder.id)
    }

    private func beginRename() {
        draftName = folder.name
        isEditing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard isEditing else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameFolder(folder.id, to: trimmed.isEmpty ? "Folder" : trimmed)
        isEditing = false
    }
}

// MARK: - Loose tabs

private struct LooseTabList: View {
    @ObservedObject var store: BrowserStore
    @Binding var draggingTabID: BrowserTab.ID?
    @State private var appendDropTargeted = false
    @State private var splitDropTargetID: BrowserTab.ID?
    @Environment(\.palette) private var p

    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(store.looseTabs.enumerated()), id: \.element.id) { idx, tab in
                TabRow(
                    tab: tab,
                    store: store,
                    isSelected: tab.id == store.selectedTabID,
                    onSelect: { store.selectTab(tab.id) },
                    onClose: { store.closeTab(tab.id) }
                )
                .transition(.tabClose)
                .overlay {
                    if splitDropTargetID == tab.id {
                        RoundedRectangle(cornerRadius: TabSurface.radius, style: .continuous)
                            .strokeBorder(p.primary.color, lineWidth: 2)
                    }
                }
                .contextMenu { TabMenu(store: store, tab: tab) }
                .onDrag {
                    draggingTabID = tab.id
                    store.beginTearOffWatch(for: tab.id)
                    return SidebarTabDrag.provider(for: tab.id)
                } preview: {
                    // Hide the cursor-following drag image: the live row already
                    // reorders in place, so a second floating copy under the
                    // pointer just reads as a confusing duplicate.
                    Color.clear.frame(width: 1, height: 1)
                }
                .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
                    target: .loose(index: idx),
                    draggingID: $draggingTabID,
                    store: store,
                    splitTargetID: tab.id,
                    splitHover: $splitDropTargetID))
            }

            // Catch zone: dropping in the empty area below the rows appends to
            // the loose list. Min height gives an always-present target even
            // when there are no loose tabs.
            SidebarDropCatchZone(height: 24,
                                 cornerRadius: Radius.sm,
                                 isTargeted: appendDropTargeted)
                .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
                    target: .loose(index: store.looseTabs.count),
                    draggingID: $draggingTabID,
                    store: store,
                    isTargeted: $appendDropTargeted))
        }
    }
}

/// Shown only while a tab drag is in flight: dropping here pulls the tab out
/// of any folder and places it at the top of the loose list. The visible
/// "drag to a non-folder" affordance.
private struct UnfolderDropZone: View {
    @ObservedObject var store: BrowserStore
    @Binding var draggingTabID: BrowserTab.ID?

    @Environment(\.palette) private var p
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(p.mutedForeground.color.opacity(targeted ? 0.9 : 0.35),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(targeted ? p.sidebarForeground.color.opacity(0.08) : .clear))
            .overlay(
                Text("Drop here to remove from folder")
                    .font(Typography.ui(Typography.small))
                    .foregroundStyle(p.mutedForeground.color))
            .frame(height: 26)
            .contentShape(Rectangle())
            .onDrop(of: SidebarTabDrag.acceptedTypes, delegate: TabReorderDropDelegate(
                target: .loose(index: 0),
                draggingID: $draggingTabID,
                store: store,
                isTargeted: $targeted,
                moveOnEnter: false))
    }
}

/// Dominant color of a favicon: average of its saturated, opaque pixels over a
/// small downsample (cached per NSImage — favicons are immutable once decoded).
enum FaviconDominantColor {
    private static let cache = NSCache<NSImage, NSColor>()

    static func color(for image: NSImage) -> NSColor? {
        if let hit = cache.object(forKey: image) { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let side = 12
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in 0..<(side * side) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255,
                pb = Double(px[i * 4 + 2]) / 255
            // Skip near-greys/whites/blacks so the brand hue dominates.
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            guard mx - mn > 0.12, mx > 0.15, mn < 0.95 else { continue }
            // Weight by saturation so vivid pixels drive the result.
            let w = mx - mn
            r += pr * w; g += pg * w; b += pb * w; n += w
        }
        guard n > 0 else { return nil }
        let color = NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
        cache.setObject(color, forKey: image)
        return color
    }
}

private struct SidebarDropCatchZone: View {
    let height: CGFloat
    let cornerRadius: CGFloat
    let isTargeted: Bool

    @Environment(\.palette) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isTargeted ? p.sidebarForeground.color.opacity(0.08) : .clear)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
    }
}

private struct NewTabRow: View {
    let action: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Icon(name: "plus", size: 15)
                    .foregroundStyle(p.mutedForeground.color)
                    .frame(width: 16)
                Text("New Tab")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.mutedForeground.color)
                Spacer()
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: TabSurface.radius, style: .continuous)
                    .fill(hovering ? p.foreground.color.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressShrinkButtonStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Tab context menu

/// Shared right-click menu for any tab row/tile.
struct TabMenu: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        Button("Rename") { store.requestTabRename(tab.id) }
        if tab.customTitle != nil {
            Button("Reset Name") { store.resetTabName(tab.id) }
        }
        Divider()
        Button(store.isPinned(tab.id) ? "Unpin" : "Pin") {
            store.togglePin(tab.id)
        }
        if !store.folders.isEmpty {
            Menu("Add to Folder") {
                ForEach(store.folders) { folder in
                    Button(folder.name) { store.addTab(tab.id, toFolder: folder.id) }
                }
            }
        }
        Button("New Folder with Tab") {
            let folder = store.addFolderForEditing()
            store.addTab(tab.id, toFolder: folder.id)
        }
        if store.folders.contains(where: { $0.tabIDs.contains(tab.id) }) {
            Button("Remove from Folder") { store.removeTabFromFolders(tab.id) }
        }
        Divider()
        Button("Always Open in This Space") { store.routeHostToActiveSpace(tab.id) }
            .disabled(!tab.urlString.hasPrefix("http"))
        Divider()
        if store.selectedTabID != tab.id, !tab.isDetached {
            Menu("Add Split View") {
                Button("Split Right") { store.splitWith(tab.id, side: .right) }
                Button("Split Left") { store.splitWith(tab.id, side: .left) }
            }
        }
        Button("Open in New Window") { store.popOutTab(tab.id) }
            .disabled(tab.isDetached)
        Button("Duplicate Tab") { store.duplicateTab(tab.id) }
        Button("Copy URL") { store.copyURL(of: tab.id) }
        ShareMenu(urlString: tab.urlString)
        Divider()
        Button {
            store.toggleKeepAwake(tab.id)
        } label: {
            if store.isKeptAwake(tab.id) {
                Label("Keep Awake", systemImage: "checkmark")
            } else {
                Text("Keep Awake")
            }
        }
        // Manual sleep is a no-op on a kept-awake tab (it's sleep-protected), so
        // hide it there rather than offer a dead action.
        if tab.hasRealized, !tab.isAsleep, !store.isKeptAwake(tab.id),
           store.selectedTabID != tab.id, store.splitTabID != tab.id {
            Button("Sleep Tab") { store.sleepTab(tab.id) }
        }
        Button("Archive Tab") { store.archiveTab(tab.id) }
            .disabled(store.isPinned(tab.id))
        Divider()
        if store.selectedTabID == tab.id {
            Button("Boost This Site…") { store.presentBoostEditor() }
            Button("Zap an Element") { store.startZapMode() }
            Divider()
        }
        if tab.isAudible || tab.isMuted {
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
            Divider()
        }
        Button("Reload") { tab.reload() }
        Button("Close Other Tabs") { store.closeOtherTabs(than: tab.id) }
            .disabled(!store.activeContext.tabIDs.contains {
                $0 != tab.id && !store.isPinned($0)
            })
        Button("Close Tabs to Right") { store.closeTabsToRight(of: tab.id) }
            .disabled(!store.hasClosableTabsToRight(of: tab.id))
        Button("Close Tab", role: .destructive) {
            store.closeTab(tab.id, forceRemove: true)
        }
    }
}

// MARK: - Bottom bar

/// Arc-style bottom bar: the Codex/AI toggle on the left, the context switcher
/// centered, and settings + the "+" menu (new tab / split / context) on the
/// right.
private struct SidebarBottomBar: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared
    @ObservedObject private var updates = UpdateNotifier.shared
    @Environment(\.palette) private var pal

    var body: some View {
        VStack(spacing: 6) {
            if let version = updates.availableVersion {
                updateBanner(version)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bar
        }
        .animation(Motion.reveal, value: updates.availableVersion)
        .onAppear { updates.start() }
    }

    /// "Millie X.Y is ready" — clicking hands off to Sparkle's update flow.
    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 8) {
            Icon(name: "arrow.down.circle.fill", size: 14)
                .foregroundStyle(pal.primary.color)
            VStack(alignment: .leading, spacing: 0) {
                Text("Millie \(version) is available")
                    .font(Typography.ui(Typography.base, weight: .semibold))
                    .foregroundStyle(pal.foreground.color)
                Text("Click to update")
                    .font(Typography.ui(Typography.small))
                    .foregroundStyle(pal.mutedForeground.color)
            }
            Spacer(minLength: 4)
            Button {
                updates.dismiss()
            } label: {
                Icon(name: "xmark", size: 10, weight: .bold)
                    .foregroundStyle(pal.mutedForeground.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss until the next release")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .fill(pal.primary.color.opacity(0.14)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .strokeBorder(pal.primary.color.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { MillieUpdater.shared.checkForUpdates() }
        .help("Download and install Millie \(version)")
    }

    private var bar: some View {
        HStack(spacing: 6) {
            if settings.aiIntegrationEnabled {
                IconButton(systemName: "glyph-millie",
                           kind: store.aiPanelVisible ? .primary : .ghost,
                           size: 30) { store.toggleAIPanel() }
                    .help("Codex AI panel")
            }
            // The Spaces live in a flexible, horizontally-scrolling middle so
            // any number of them stays clear of the fixed side controls instead
            // of overlapping them (the old centered ZStack collided at 5+).
            ScrollView(.horizontal, showsIndicators: false) {
                ContextSwitcherStrip(store: store)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            IconButton(systemName: "gearshape", size: 30) { store.toggleSettings() }
                .help("Settings")
            PlusMenuButton(store: store)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }
}

// MARK: - Context header

/// The active context's name atop the tab list, à la Arc's space title.
/// Double-click renames inline; right-click offers context management.
private struct ContextHeaderRow: View {
    @ObservedObject var store: BrowserStore

    @Environment(\.palette) private var p
    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Icon(name: store.activeContext.symbol, size: 12)
                .foregroundStyle(p.mutedForeground.color)
            if isEditing {
                TextField("Context", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Typography.ui(Typography.label, weight: .semibold))
                    .foregroundStyle(p.sidebarForeground.color.opacity(0.85))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(store.activeContext.name)
                    .font(Typography.ui(Typography.label, weight: .semibold))
                    .foregroundStyle(p.sidebarForeground.color.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: beginRename)
        .contextMenu {
            Button("Rename") { beginRename() }
            Button("New Context…") { store.contextCreationVisible = true }
            Divider()
            Button("Delete Context", role: .destructive) {
                store.deleteContext(store.activeContextID)
            }
            .disabled(store.contexts.count <= 1)
        }
    }

    private func beginRename() {
        draftName = store.activeContext.name
        isEditing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard isEditing else { return }
        store.renameContext(store.activeContextID, to: draftName)
        isEditing = false
    }
}

// (The light/dark toggle and theme swatch that used to live here moved out of
// the bottom bar: appearance lives in Settings, and themes are per-context via
// the context switcher's editor.)

// MARK: - Space swipe (two-finger trackpad navigation)

/// Transparent backing view that detects two-finger horizontal trackpad swipes
/// over the sidebar and switches to the adjacent Space. A vertical `ScrollView`
/// would otherwise absorb the scroll, so this watches scroll-wheel events with a
/// scoped local monitor: horizontal-dominant precise scrolls over the sidebar
/// are consumed and converted to a Space switch; vertical scrolls pass through
/// so the tab list still scrolls. `hitTest` returns nil so clicks/drags on the
/// SwiftUI content above are never intercepted.
private struct SpaceSwipeCatcher: NSViewRepresentable {
    /// -1 = previous Space, +1 = next.
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onSwipe = onSwipe
    }

    final class MonitorView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumX: CGFloat = 0
        private var armed = true
        private var cooldownUntil: TimeInterval = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installIfNeeded()
            } else {
                removeMonitor()
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        /// Returns true when the event was consumed as a Space swipe.
        private func handle(_ event: NSEvent) -> Bool {
            guard let win = window, event.window === win else { return false }
            // Only horizontal-dominant precise (trackpad) scrolls over this view.
            guard event.hasPreciseScrollingDeltas else { return false }
            let frame = convert(bounds, to: nil)
            guard frame.contains(event.locationInWindow) else { return false }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) > abs(dy) * 1.5 else { return false }

            switch event.phase {
            case .began: accumX = 0; armed = true
            case .ended, .cancelled: accumX = 0
            default: break
            }
            accumX += dx

            let now = ProcessInfo.processInfo.systemUptime
            if armed, now > cooldownUntil, abs(accumX) > 55 {
                armed = false
                cooldownUntil = now + 0.45
                // Swipe right (positive dx) → previous Space, like page-back.
                let direction = accumX > 0 ? -1 : 1
                let handler = onSwipe
                DispatchQueue.main.async { handler?(direction) }
            }
            return true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A "Share" submenu for a page URL: Copy Link plus the native macOS sharing
/// services (AirDrop, Mail, Messages, Notes, Reminders, …), matching the system
/// share sheet. Enumerates the services that accept the URL and performs the one
/// the user picks. Disabled for non-web pages (nothing to share).
struct ShareMenu: View {
    let urlString: String

    var body: some View {
        Menu("Share") {
            Button("Copy Link") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(urlString, forType: .string)
                ToastCenter.shared.show("Link copied", icon: "link", style: .success)
            }
            let services = shareServices
            if !services.isEmpty {
                Divider()
                ForEach(Array(services.enumerated()), id: \.offset) { _, service in
                    Button {
                        guard let url = URL(string: urlString) else { return }
                        service.perform(withItems: [url])
                    } label: {
                        Label { Text(service.title) } icon: { Image(nsImage: service.image) }
                    }
                }
            }
        }
        .disabled(!isShareable)
    }

    private var isShareable: Bool {
        urlString.hasPrefix("http://") || urlString.hasPrefix("https://")
    }

    private var shareServices: [NSSharingService] {
        guard isShareable, let url = URL(string: urlString) else { return [] }
        // Deprecated in macOS 13 in favor of NSSharingServicePicker, but it's the
        // only way to render the services inline as menu items (the picker shows
        // its own popover). Still fully functional.
        return NSSharingService.sharingServices(forItems: [url])
    }
}
