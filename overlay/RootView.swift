import SwiftUI

/// The complete browser chrome: a primary vertical tab/sidebar rail, main web
/// content, and optional side panels.
struct RootView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared
    @ObservedObject private var extensionStore = ExtensionStore.shared
    @Environment(\.colorScheme) private var systemScheme
    /// Live hover side while a sidebar tab is dragged over the web card.
    @State private var splitDropSide: BrowserStore.SplitSide?
    @State private var webCardWidth: CGFloat = 800

    private var gradientTheme: GradientTheme { settings.gradientTheme }

    private var scheme: ColorScheme {
        GradientEngine.effectiveScheme(
            for: gradientTheme,
            base: settings.theme.colorScheme ?? systemScheme
        )
    }

    private var palette: ThemePalette {
        ThemePalette.forScheme(scheme).applying(theme: gradientTheme, scheme: scheme)
    }

    var body: some View {
        let activeTab = store.selectedTab ?? store.tabs.first

        HStack(spacing: 0) {
            if settings.sidebarPosition == .left {
                sidebarSlot(onLeft: true)
            }

            // AI panel opens on the side opposite the tab sidebar: when the
            // sidebar sits on the right, the AI panel slides in from the left.
            if store.aiPanelVisible, settings.aiIntegrationEnabled, settings.sidebarPosition == .right {
                AIPanel(store: store)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Web content column — the toolbar chrome plus a floating, rounded
            // "card" that encapsulates the live browser, Arc-style.
            VStack(spacing: 0) {
                WebTopStrip(tab: activeTab)
                webCard(activeTab: activeTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // AI panel on the right, when the sidebar sits on the left.
            if store.aiPanelVisible, settings.aiIntegrationEnabled, settings.sidebarPosition == .left {
                AIPanel(store: store)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if extensionStore.sidePanelExtensionID != nil {
                ExtensionSidePanel()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if settings.sidebarPosition == .right {
                sidebarSlot(onLeft: false)
            }
        }
        // Hover-to-peek sidebar — full-window overlay above the web view,
        // anchored to the selected sidebar edge, live only while hidden.
        .overlay {
            SidebarPeekOverlay(store: store, palette: palette, scheme: scheme,
                               gradientTheme: gradientTheme,
                               enabled: !store.sidebarVisible,
                               sidebarPosition: settings.sidebarPosition)
                .ignoresSafeArea()
        }
        // New-tab launcher (command palette) — full-window overlay so it centers
        // relative to the entire app window, not just the web card.
        .overlay {
            LauncherOverlay(store: store, palette: palette, scheme: scheme)
                .ignoresSafeArea()
        }
        // Ctrl+Tab preview switcher HUD (mirrors the in-progress MRU cycle).
        .overlay {
            TabSwitcherOverlay(store: store)
                .animation(Motion.reveal, value: store.switcherVisible)
                .ignoresSafeArea()
        }
        // Per-site Boost editor (custom CSS/JS + zaps).
        .overlay {
            BoostEditorOverlay(store: store)
                .ignoresSafeArea()
        }
        // Transient Peek preview (Little Arc-style link glance).
        .overlay {
            PeekOverlay(store: store)
                .ignoresSafeArea()
        }
        // Custom right-click menu for links & images.
        .overlay {
            WebContextMenuOverlay(store: store)
                .ignoresSafeArea()
        }
        // Screenshot region selector (AppKit-hosted, above the web view).
        .overlay {
            CaptureOverlay(store: store)
                .ignoresSafeArea()
        }
        // Site permission requests — notification-style, non-modal chrome that
        // still reports Allow / Block / Not Now back to Chromium.
        .overlay {
            PermissionPromptOverlay(center: PermissionPromptCenter.shared)
                .ignoresSafeArea()
        }
        .background {
            WebRightClickCatcher(store: store)
                .frame(width: 0, height: 0)
        }
        // Transient notifications (link copied, etc.) — bottom-centered above
        // everything so they read clearly regardless of the active panel.
        .overlay {
            ToastOverlay(center: ToastCenter.shared)
                .ignoresSafeArea()
        }
        // Keyboard-shortcuts cheat-sheet (⌘/).
        .overlay {
            ShortcutsHelpOverlay(store: store)
                .animation(Motion.reveal, value: store.shortcutsHelpVisible)
                .ignoresSafeArea()
        }
        .environment(\.palette, palette)
        .preferredColorScheme(scheme)
        .background {
            // One unified chrome surface behind everything: the floating card's
            // inset gaps and the sidebar share this exact material + tint, so
            // there's no color step between them. A custom gradient theme washes
            // this surface with the picked colors (plus optional grain); with no
            // theme set it falls back to the plain sidebar tint.
            ZStack {
                VisualEffectBackground(material: .sidebar)
                if gradientTheme.isEmpty {
                    palette.sidebar.color.opacity(0.55)
                } else {
                    GradientEngine.chromeView(for: gradientTheme, scheme: scheme)
                        .opacity(gradientTheme.opacity)
                    if gradientTheme.texture > 0 {
                        GrainOverlay(amount: gradientTheme.texture)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .animation(Motion.reveal, value: store.aiPanelVisible)
        .animation(Motion.snappy, value: store.sidebarVisible)
        .animation(Motion.snappy, value: settings.sidebarPosition)
    }

    private func sidebarSlot(onLeft: Bool) -> some View {
        let width = settings.sidebarWidth
        return Sidebar(store: store)
            .frame(width: width)
            .frame(width: store.sidebarVisible ? width : 0,
                   alignment: onLeft ? .leading : .trailing)
            .clipped()
            .allowsHitTesting(store.sidebarVisible)
            .accessibilityHidden(!store.sidebarVisible)
    }

    /// The browser, wrapped in a floating rounded card with a hairline border
    /// and a soft drop shadow, inset from the window edges so the chrome reads
    /// as a frame around the content (à la Arc).
    @ViewBuilder
    private func webCard(activeTab: BrowserTab?) -> some View {
        ZStack {
            // Card surface + shadow live on a real SwiftUI shape so the shadow
            // hugs the rounded corners (a clipped NSView can't cast one itself).
            RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                .fill(palette.card.color)
                .elevation(.card, scheme)

            if let activeTab {
                ActiveWebContent(store: store,
                                 tab: activeTab,
                                 cornerRadius: Radius.window)
            }

            // Settings renders as a full page inside the card, on top of the
            // (suppressed) web content — not as a modal sheet.
            if store.settingsVisible {
                SettingsView(store: store)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
            }

            // While the sidebar is being resized the CEF view is frozen (see
            // WebContainerView); cover it with the plain card surface so the
            // user sees a clean, smoothly-resizing card instead of the static,
            // clipped page underneath.
            if store.isResizingSidebar {
                RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                    .fill(palette.card.color)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.findBarVisible, let tab = activeTab {
                FindBar(store: store, tab: tab)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            // Page-load indicator: a slim muted bar pinned to the bottom edge of
            // the page, clipped to the card's rounded corners.
            if let activeTab, activeTab.isLoading {
                LoadingBar()
                    .padding(.horizontal, Radius.window)
                    .padding(.bottom, 1)
                    .transition(.opacity)
                    .animation(Motion.state, value: activeTab.isLoading)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                .strokeBorder(palette.border.color.opacity(0.7), lineWidth: 1)
        )
        // Zen-style split: drag a sidebar tab over the card to split it.
        .overlay {
            if let side = splitDropSide {
                SplitDropPreview(side: side)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.window,
                                                style: .continuous))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: store.splitSide == .left ? .topLeading : .topTrailing) {
            if store.splitTabID != nil {
                Button { store.closeSplit() } label: {
                    Icon(name: "xmark", size: 10, weight: .bold)
                        .foregroundStyle(palette.mutedForeground.color)
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close split")
                .padding(10)
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { webCardWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in webCardWidth = w }
            }
        }
        .onDrop(of: SidebarTabDrag.acceptedTypes,
                delegate: SplitDropDelegate(store: store,
                                            hoverSide: $splitDropSide,
                                            width: webCardWidth))
        .animation(Motion.snappy, value: splitDropSide != nil)
        .padding(.top, 4)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }
}

/// The drop-zone preview while dragging a tab over the web card: the half
/// being targeted is greyed/muted (the new tab lands there); the other half
/// keeps showing the existing page.
private struct SplitDropPreview: View {
    let side: BrowserStore.SplitSide
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            zone(active: side == .left)
            zone(active: side == .right)
        }
    }

    @ViewBuilder
    private func zone(active: Bool) -> some View {
        ZStack {
            if active {
                Rectangle().fill(Color.black.opacity(0.35))
                VStack(spacing: 8) {
                    Icon(name: "plus", size: 22, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Split here")
                        .font(Typography.ui(Typography.base, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Accepts a sidebar tab drag on the web card and turns it into a split.
private struct SplitDropDelegate: DropDelegate {
    let store: BrowserStore
    @Binding var hoverSide: BrowserStore.SplitSide?
    let width: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: SidebarTabDrag.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        hoverSide = side(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoverSide = side(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        hoverSide = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let side = side(for: info)
        hoverSide = nil
        guard let provider = info.itemProviders(for: SidebarTabDrag.acceptedTypes).first else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString,
                  let id = UUID(uuidString: string as String) else { return }
            DispatchQueue.main.async {
                store.splitWith(id, side: side)
            }
        }
        return true
    }

    private func side(for info: DropInfo) -> BrowserStore.SplitSide {
        // DropInfo.location is in the receiving view's coordinate space.
        info.location.x < width / 2 ? .left : .right
    }
}

private struct ActiveWebContent: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    let cornerRadius: CGFloat

    var body: some View {
        WebContainerView(store: store, activeTab: tab, cornerRadius: cornerRadius)

        if tab.didFail {
            ErrorOverlay(tab: tab)
        }
    }
}

private struct GrainOverlay: View {
    let amount: Double

    var body: some View {
        ZStack {
            Color.white.opacity(0.035 * amount)
                .blendMode(.overlay)
            Color.black.opacity(0.025 * amount)
                .blendMode(.multiply)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Chrome's real extension side panel (an ExtensionViewHost owned by the
/// native bridge), framed by Millie's side panel chrome.
private struct ExtensionSidePanel: View {
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Icon(name: "sidebar.trailing", size: 15, weight: .regular)
                    .foregroundStyle(p.primary.color)
                Text(extensions.sidePanelTitle ?? "Extension")
                    .font(Typography.ui(Typography.title, weight: .semibold))
                    .foregroundStyle(p.foreground.color)
                    .lineLimit(1)
                Spacer()
                IconButton(systemName: "xmark", size: 28,
                           help: "Close panel") {
                    extensions.closeSidePanel()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Hairline().opacity(0.6)

            ExtensionSidePanelHost(extensionID: extensions.sidePanelExtensionID ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 360)
        .background {
            ZStack {
                VisualEffectBackground(material: .menu)
                p.background.color.opacity(0.45)
            }
            .ignoresSafeArea()
        }
    }
}

/// Embeds the side panel host's native (WebContents) view. The bridge owns the
/// host's lifetime; this container only attaches/detaches the view.
private struct ExtensionSidePanelHost: NSViewRepresentable {
    let extensionID: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        guard let panelView = MoriChromeExtensions.sidePanelView() else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if panelView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            panelView.frame = container.bounds
            panelView.autoresizingMask = [.width, .height]
            container.addSubview(panelView)
        }
    }
}

/// A lightweight failed-load overlay (e.g. no network / bad host).
private struct ErrorOverlay: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 12) {
            Icon(name: "wifi.exclamationmark", size: 40, weight: .light)
                .foregroundStyle(p.mutedForeground.color)
            Text("This page couldn't load")
                .font(Typography.ui(Typography.title, weight: .medium))
                .foregroundStyle(p.foreground.color)
            Text(tab.urlString)
                .font(Typography.mono(12))
                .foregroundStyle(p.mutedForeground.color)
                .lineLimit(1)
                .truncationMode(.middle)

            // Surface the underlying failure (DNS, timeout, SSL, …) so the user
            // can actually diagnose the problem instead of a generic message.
            if !tab.failError.isEmpty {
                Text(tab.failError)
                    .font(Typography.ui(Typography.small))
                    .foregroundStyle(p.mutedForeground.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    tab.didFail = false
                    tab.failError = ""
                } label: {
                    Text("Dismiss")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.foreground.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                .fill(p.muted.color.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    tab.reload()
                } label: {
                    Text("Reload")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.primaryForeground.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                                .fill(p.primary.color)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .fill(p.card.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
        )
    }
}

/// Ctrl+Tab preview switcher: a transient HUD that lists the most-recently-used
/// tabs as cards while a cycle is in progress, highlighting the one that will be
/// selected on release. Non-interactive — it only mirrors the cycle state.
private struct TabSwitcherOverlay: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    private static let accent = Color(.sRGB, red: 0.24, green: 0.37, blue: 0.99, opacity: 1)

    var body: some View {
        if store.switcherVisible, store.switcherTabIDs.count > 1 {
            let tabs = store.switcherTabIDs.compactMap { id in
                store.tabs.first { $0.id == id }
            }
            VStack {
                Spacer()
                content(tabs)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func content(_ tabs: [BrowserTab]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                    card(tab, highlighted: idx == store.switcherIndex)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: 760)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .fill(p.popover.color)
                .elevation(.modal, scheme)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 40)
    }

    private func card(_ tab: BrowserTab, highlighted: Bool) -> some View {
        VStack(spacing: 9) {
            Favicon(icon: tab.faviconURL, page: tab.urlString,
                    image: tab.faviconImage, size: 30)
                .frame(height: 34)
            Text(tab.displayTitle.isEmpty ? tab.displayURL : tab.displayTitle)
                .font(Typography.ui(Typography.small, weight: .medium))
                .foregroundStyle(highlighted ? p.foreground.color : p.mutedForeground.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 144, height: 104)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(highlighted ? Self.accent.opacity(0.16) : p.input.color.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(highlighted ? Self.accent : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Keyboard shortcuts cheat-sheet (⌘/)

/// A read-only overlay listing Millie's keyboard shortcuts, grouped by area.
/// Opened with ⌘/ or from Settings; dismissed with Esc / click-outside / ✕.
private struct ShortcutsHelpOverlay: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let items: [(keys: String, label: String)]
    }

    private let groups: [Group] = [
        Group(title: "Tabs", items: [
            ("⌘T", "New tab / command bar"),
            ("⌘L", "Focus address bar"),
            ("⌘W", "Close tab"),
            ("⌘⇧T", "Reopen closed tab"),
            ("⌘⇧D", "Duplicate tab"),
            ("⌘⇧P", "Pin / unpin tab"),
            ("⌃Tab", "Next tab (most-recently-used)"),
            ("⌃⇧Tab", "Previous tab (most-recently-used)"),
            ("⌘1–9", "Jump to tab 1–9"),
        ]),
        Group(title: "Spaces", items: [
            ("⌃1–9", "Switch to Space 1–9"),
            ("⌃⇧]", "Next Space"),
            ("⌃⇧[", "Previous Space"),
            ("Two-finger swipe", "Switch Spaces (over the sidebar)"),
        ]),
        Group(title: "Navigation", items: [
            ("⌘[", "Back"),
            ("⌘]", "Forward"),
            ("⌘R", "Reload"),
            ("⌘⇧R", "Force reload (ignore cache)"),
            ("⌘.", "Stop"),
            ("⌘⇧H", "Home"),
        ]),
        Group(title: "Page", items: [
            ("⌘F", "Find in page"),
            ("⌘G", "Find next"),
            ("⌘⇧G", "Find previous"),
            ("⌘= / ⌘-", "Zoom in / out"),
            ("⌘0", "Reset zoom"),
            ("⌘P", "Print"),
            ("⌘⇧C", "Copy current URL"),
        ]),
        Group(title: "View & tools", items: [
            ("⌘S", "Toggle sidebar"),
            ("⌃⇧=", "New split view"),
            ("⌘⇧S", "Close split"),
            ("⌘⇧O", "Peek a link"),
            ("⌘⇧B", "Boost this site"),
            ("⌘⌃S", "Sleep background tabs"),
            ("⌘⌥I", "Developer tools"),
            ("⌘K", "Assistant"),
        ]),
        Group(title: "App", items: [
            ("⌘,", "Settings"),
            ("⌘/", "This shortcuts list"),
            ("⌘M", "Minimize"),
            ("⌘H", "Hide Millie"),
            ("⌘Q", "Quit"),
        ]),
    ]

    var body: some View {
        if store.shortcutsHelpVisible {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { store.shortcutsHelpVisible = false }

                card
            }
            .transition(.opacity)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(Typography.ui(Typography.title, weight: .semibold))
                    .foregroundStyle(p.foreground.color)
                Spacer()
                Button { store.shortcutsHelpVisible = false } label: {
                    Icon(name: "xmark", size: 13, weight: .semibold)
                        .foregroundStyle(p.mutedForeground.color)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(p.input.color.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle().fill(p.border.color.opacity(0.5)).frame(height: 1)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .top),
                              GridItem(.flexible(), alignment: .top)],
                    alignment: .leading, spacing: 22
                ) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(Typography.ui(Typography.label, weight: .semibold))
                                .foregroundStyle(p.mutedForeground.color)
                            ForEach(group.items, id: \.label) { item in
                                HStack(spacing: 10) {
                                    Text(item.label)
                                        .font(Typography.ui(Typography.base))
                                        .foregroundStyle(p.foreground.color)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    Text(item.keys)
                                        .font(Typography.ui(12, weight: .medium))
                                        .foregroundStyle(p.foreground.color)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(p.input.color.opacity(0.6))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(p.border.color.opacity(0.7), lineWidth: 1)
                                        )
                                        .fixedSize()
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 640)
        .background(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .fill(p.popover.color)
                .elevation(.modal, scheme)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
        )
        .padding(40)
    }
}
