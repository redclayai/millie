import SwiftUI
import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

/// The new-tab launcher — a Spotlight-style command palette floated above the
/// web content. Triggered by ⌘T / the sidebar's "New Tab" row instead of
/// silently spawning a blank tab, it lets you search, jump to an already-open
/// tab, or pick from history before a tab is ever created.
///
/// Like the sidebar peek, this must be AppKit-hosted: the live CEF browser
/// composites *above* SwiftUI `.overlay`s and would otherwise cover the palette
/// and swallow its clicks. Hosting an `NSView` above the web view (and gating
/// `hitTest`) puts the palette on top and lets it take keyboard focus.
struct LauncherOverlay: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    var palette: ThemePalette
    var scheme: ColorScheme

    func makeNSView(context: Context) -> LauncherContainerView {
        let view = LauncherContainerView()
        view.update(store: store, palette: palette, scheme: scheme)
        return view
    }

    func updateNSView(_ nsView: LauncherContainerView, context: Context) {
        nsView.update(store: store, palette: palette, scheme: scheme)
    }
}

/// Hosts the palette UI above the web view and gates interaction via `hitTest`:
/// fully click-through when closed, modal (captures everything) when open.
final class LauncherContainerView: NSView {
    private var hosting: NSHostingView<AnyView>?
    private weak var store: BrowserStore?
    private var palette: ThemePalette = .light
    private var scheme: ColorScheme = .light
    private var visible = false
    /// Drives show/hide straight off `launcherVisible` instead of SwiftUI's
    /// `updateNSView` pass. A keyboard ⌘T mutates the store from outside SwiftUI,
    /// and the chrome flush forces synchronous layouts; that racing of forced
    /// layout against SwiftUI's representable reconcile made `updateNSView` read
    /// a *stale* `launcherVisible` on rapid toggles (open then close inside the
    /// ~0.35s flush window), so the palette got stuck open. The publisher always
    /// carries the authoritative new value synchronously on `willSet`, making
    /// the toggle reliable regardless of flush/layout timing.
    private var visibilityObserver: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        hosting = host
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update(store: BrowserStore, palette: ThemePalette, scheme: ColorScheme) {
        let storeChanged = self.store !== store
        self.store = store
        // Keep palette/scheme current so the *next* open is styled correctly;
        // visibility transitions are owned by the publisher subscription below,
        // not this (frequently re-invoked, and timing-racy) update pass.
        self.palette = palette
        self.scheme = scheme

        guard storeChanged else { return }
        // Subscribe once: a @Published publisher emits the current value on
        // subscribe, then the new value on every change — synchronously, so the
        // launcher can never be left out of sync with the store.
        visibilityObserver = store.$launcherVisible.sink { [weak self] newVisible in
            self?.applyVisible(newVisible)
        }
    }

    private func applyVisible(_ nowVisible: Bool) {
        guard nowVisible != visible else { return }
        visible = nowVisible
        rebuild(visible: nowVisible)
    }

    private func rebuild(visible: Bool) {
        guard let store else { return }
        hosting?.rootView = AnyView(
            Group {
                if visible {
                    LauncherView(store: store, scheme: scheme)
                        .environment(\.palette, palette)
                }
            }
        )
        // The toggle came from outside SwiftUI; draw the change now rather than
        // waiting for the next event to pump the run loop.
        needsLayout = true
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Modal while open; otherwise let every click reach the web view.
        guard visible else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        hosting?.frame = bounds
    }
}

// MARK: - Palette UI

/// Arc-style site search for the launcher: type a site's keyword ("youtube",
/// "yt"), press Tab (or Space after the bare keyword), and a colored chip
/// locks in — everything typed after searches that site directly.
struct SiteSearch: Identifiable, Equatable {
    let id: String          // canonical keyword
    let name: String        // chip label
    let aliases: [String]   // extra keywords ("yt")
    let hex: String         // chip color
    let template: String    // search URL, {query} substituted
    let home: String        // opened when the query is empty

    var color: Color { TokenColor(hex: hex).color }

    func url(for query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return home }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/#")
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        return template.replacingOccurrences(of: "{query}", with: encoded)
    }

    static let all: [SiteSearch] = [
        SiteSearch(id: "youtube", name: "YouTube", aliases: ["yt"], hex: "#FF0000",
                   template: "https://www.youtube.com/results?search_query={query}",
                   home: "https://www.youtube.com"),
        SiteSearch(id: "google", name: "Google", aliases: ["g"], hex: "#4285F4",
                   template: "https://www.google.com/search?q={query}",
                   home: "https://www.google.com"),
        SiteSearch(id: "wikipedia", name: "Wikipedia", aliases: ["wiki"], hex: "#5B6470",
                   template: "https://en.wikipedia.org/wiki/Special:Search?search={query}",
                   home: "https://en.wikipedia.org"),
        SiteSearch(id: "reddit", name: "Reddit", aliases: ["r"], hex: "#FF4500",
                   template: "https://www.reddit.com/search/?q={query}",
                   home: "https://www.reddit.com"),
        SiteSearch(id: "github", name: "GitHub", aliases: ["gh"], hex: "#24292F",
                   template: "https://github.com/search?q={query}&type=repositories",
                   home: "https://github.com"),
        SiteSearch(id: "amazon", name: "Amazon", aliases: ["az"], hex: "#FF9900",
                   template: "https://www.amazon.com/s?k={query}",
                   home: "https://www.amazon.com"),
        SiteSearch(id: "x", name: "X", aliases: ["twitter"], hex: "#111111",
                   template: "https://x.com/search?q={query}",
                   home: "https://x.com"),
        SiteSearch(id: "maps", name: "Maps", aliases: ["map"], hex: "#34A853",
                   template: "https://www.google.com/maps/search/{query}",
                   home: "https://www.google.com/maps"),
        SiteSearch(id: "perplexity", name: "Perplexity", aliases: ["px"], hex: "#20808D",
                   template: "https://www.perplexity.ai/search?q={query}",
                   home: "https://www.perplexity.ai"),
    ]

    /// The provider whose keyword/alias exactly matches `text` (trimmed,
    /// case-insensitive), if any.
    static func match(_ text: String) -> SiteSearch? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return all.first { $0.id == key || $0.aliases.contains(key) }
    }
}

private struct LauncherView: View {
    @ObservedObject var store: BrowserStore
    var scheme: ColorScheme
    @Environment(\.palette) private var p

    @State private var query = ""
    @State private var highlighted = 0
    @State private var siteSearch: SiteSearch?
    /// Live keyless query suggestions (Google suggest). Owned here so it lives
    /// for the duration of one launcher presentation and cancels cleanly.
    @StateObject private var suggest = SuggestClient()
    /// Live speech-to-text for the mic button; streams into `query` while active.
    @StateObject private var dictation = SpeechDictation()

    /// "Add tabs or files" selections, shown as removable chips and gathered as
    /// Ask-Millie context on submit.
    @State private var attachedTabIDs: [UUID] = []
    @State private var attachedFiles: [URL] = []
    @State private var showingAttachPicker = false

    private var hasAttachments: Bool {
        !attachedTabIDs.isEmpty || !attachedFiles.isEmpty
    }

    private var items: [LauncherItem] {
        // Chip active → one canonical row; Enter and the row do the same thing.
        if let ss = siteSearch {
            let title = query.isEmpty ? "Search \(ss.name)…"
                                      : "Search \(ss.name) for “\(query)”"
            return [LauncherItem(id: "site-search", title: title,
                                 url: ss.url(for: query), faviconURL: nil,
                                 tabID: nil, action: "Search",
                                 iconSystemName: "magnifyingglass",
                                 run: { commitSiteSearch() })]
        }
        var out = LauncherItem.build(query: query, store: store,
                                     suggestions: suggestionsForCurrentQuery)
        // Keyword typed but not yet activated → offer the chip as the top row.
        if let match = SiteSearch.match(query) {
            out.insert(LauncherItem(id: "site-hint-\(match.id)",
                                    title: "Search \(match.name)",
                                    url: match.home, faviconURL: nil,
                                    tabID: nil, action: "Tab",
                                    iconSystemName: match.id == "google" ? "magnifyingglass" : "globe",
                                    run: { activateSiteSearch(match) }),
                       at: 0)
        }
        return out
    }

    /// Suggestions, but only when they belong to the text now in the field
    /// (a late response for a stale query is ignored by matching on the trim).
    private var suggestionsForCurrentQuery: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggest.activeQuery == trimmed else { return [] }
        return suggest.suggestions
    }

    /// Inline ghost-autocomplete target: the host of the first address/site
    /// result whose host begins with what the user has typed. `nil` disables
    /// completion (phrases, chips, empty, paths, already-complete hosts).
    private var inlineCompletion: String? {
        guard siteSearch == nil else { return nil }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(" "), !typed.contains("/"),
              !typed.contains("://") else { return nil }
        let typedLower = typed.lowercased()
        for item in items {
            guard let host = item.completionHost else { continue }
            if host.lowercased().hasPrefix(typedLower), host.count > typed.count {
                return host
            }
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Invisible click-outside target; the page behind the launcher
                // should stay visually unchanged.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissLauncher() }

                // Pin the card's *top* edge to a fixed fraction down from the
                // top of the window (Spotlight-style) so it only ever grows
                // downward — its position stays fixed regardless of how many
                // results are rendered.
                card
                    .frame(maxWidth: LauncherMetrics.cardWidth)
                    .padding(.horizontal, LauncherMetrics.horizontalPadding)
                    .padding(.top, geo.size.height * LauncherMetrics.topFraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            resetForPresentation()
        }
        .onChange(of: store.launcherFocusRequest) { _, _ in
            resetForPresentation()
        }
        .onChange(of: query) { _, text in
            highlighted = 0
            autoActivateOnSpace(text)
            // Fire-and-forget: debounced, cancels in flight, fails silent.
            if siteSearch == nil {
                suggest.request(for: text)
            } else {
                suggest.clear()
            }
        }
        // Mirror the live dictation transcript into the search field while the
        // mic is active, so speech drives the same query the user types into.
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.isListening, !text.isEmpty else { return }
            query = text
        }
        .onDisappear {
            suggest.clear()
            dictation.stop()
        }
    }

    private func resetForPresentation() {
        // Seed from the address bar (current URL) when invoked there; blank
        // for a Cmd-T launcher. Address-bar text is selected by the AppKit
        // field so the first keystroke replaces it wholesale.
        query = store.launcherPrefill
        highlighted = 0
        siteSearch = nil
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            if hasAttachments {
                attachmentChips
            }

            if !items.isEmpty {
                Rectangle()
                    .fill(p.border.color.opacity(0.4))
                    .frame(height: 1)
                    .padding(.horizontal, LauncherMetrics.headerPadding)
                results
            }

            Rectangle()
                .fill(p.border.color.opacity(0.4))
                .frame(height: 1)
                .padding(.horizontal, LauncherMetrics.headerPadding)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: LauncherMetrics.cornerRadius, style: .continuous)
                .fill(p.popover.color)
                .elevation(.modal, scheme)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LauncherMetrics.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [.white.opacity(0.1), .white.opacity(0.03)]
                            : [.black.opacity(0.06), .black.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        // Swallow taps on the card so they don't fall through to the scrim.
        .contentShape(RoundedRectangle(cornerRadius: LauncherMetrics.cornerRadius, style: .continuous))
        .onTapGesture {}
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { store.dismissLauncher(); return .handled }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Icon(name: "magnifyingglass", size: 20, weight: .medium)
                .foregroundStyle(p.mutedForeground.color.opacity(0.65))

            if let ss = siteSearch {
                Text(ss.name)
                    .font(Typography.ui(Typography.base, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(ss.color))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(siteSearch == nil ? "Search or Enter URL…" : "Search…")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(p.mutedForeground.color.opacity(0.6))
                }
                LauncherSearchField(text: $query,
                                    focusRequest: store.launcherFocusRequest,
                                    selectAllOnFocus: !store.launcherPrefill.isEmpty,
                                    foregroundColor: p.foreground.nsColor,
                                    insertionColor: p.primary.nsColor,
                                    completionColor: p.mutedForeground.nsColor,
                                    inlineCompletion: inlineCompletion,
                                    onMove: move,
                                    onEscape: store.dismissLauncher,
                                    onSubmit: commit,
                                    onTab: handleTab,
                                    onEmptyDelete: handleEmptyDelete,
                                    onAcceptInline: acceptInlineCompletion,
                                    onAcceptInlineSubmit: acceptInlineCompletionAndOpen)
                    .frame(height: 30)
            }

            Button {
                store.dismissLauncher()
                store.settingsVisible = true
            } label: {
                Icon(name: "info.circle", size: 18, weight: .medium)
                    .foregroundStyle(LauncherMetrics.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(LauncherMetrics.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, LauncherMetrics.headerPadding)
        .frame(height: LauncherMetrics.headerHeight)
    }

    /// Dia-style bottom action bar: a left "Add tabs or files" pill and overflow
    /// control, a right-side mic glyph, and a primary "Go ↵" button that fires
    /// the current selection (identical to Enter).
    private var footer: some View {
        HStack(spacing: 8) {
            // "Add tabs or files" — opens a picker of open tabs + a file chooser,
            // staging them as Ask-Millie context.
            Button { showingAttachPicker.toggle() } label: {
                softPillShape {
                    HStack(spacing: 6) {
                        Icon(name: "plus", size: 12, weight: .semibold)
                        Text("Add tabs or files")
                            .font(Typography.ui(Typography.label, weight: .medium))
                    }
                    .foregroundStyle(hasAttachments ? LauncherMetrics.accent : p.mutedForeground.color)
                    .padding(.horizontal, 12)
                    .frame(height: LauncherMetrics.footerControl)
                }
            }
            .buttonStyle(.plain)
            .help("Add open tabs or files as context for Ask Millie")
            .popover(isPresented: $showingAttachPicker, arrowEdge: .top) {
                AttachPicker(store: store,
                             attachedTabIDs: $attachedTabIDs,
                             attachedFiles: $attachedFiles,
                             chooseFiles: chooseFiles)
                    .environment(\.palette, p)
            }

            // Overflow — opens Settings (a sensible, non-crashing destination).
            Button {
                store.dismissLauncher()
                store.settingsVisible = true
            } label: {
                softPillShape {
                    Icon(name: "ellipsis", size: 15, weight: .semibold)
                        .foregroundStyle(p.mutedForeground.color)
                        .frame(width: LauncherMetrics.footerControl,
                               height: LauncherMetrics.footerControl)
                }
            }
            .buttonStyle(.plain)
            .help("More")

            Spacer(minLength: 0)

            // Mic — toggles live dictation into the search field.
            Button { dictation.toggle() } label: {
                softPillShape {
                    Icon(name: dictation.isListening ? "mic.fill"
                             : (dictation.unavailable ? "mic.slash" : "mic"),
                         size: 15, weight: .medium)
                        .foregroundStyle(micTint)
                        .frame(width: LauncherMetrics.footerControl,
                               height: LauncherMetrics.footerControl)
                }
            }
            .buttonStyle(.plain)
            .help(dictation.isListening ? "Stop dictation"
                      : (dictation.unavailable ? "Dictation unavailable" : "Dictate"))

            // Go — activates the current selection, exactly like Enter.
            Button { commit() } label: {
                HStack(spacing: 6) {
                    Text("Go")
                        .font(Typography.ui(Typography.base, weight: .semibold))
                    Icon(name: "return", size: 12, weight: .semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(height: LauncherMetrics.footerControl + 2)
                .background(Capsule(style: .continuous).fill(LauncherMetrics.accent))
            }
            .buttonStyle(.plain)
            .help("Go")
        }
        .padding(.horizontal, LauncherMetrics.headerPadding)
        .frame(height: LauncherMetrics.footerHeight)
    }

    /// A soft neutral pill used by the footer's secondary controls.
    @ViewBuilder private func softPill<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        softPillShape(content)
    }

    @ViewBuilder private func softPillShape<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .background(Capsule(style: .continuous).fill(p.foreground.color.opacity(0.05)))
    }

    private var micTint: Color {
        if dictation.isListening { return Color(.sRGB, red: 0.90, green: 0.22, blue: 0.22, opacity: 1) }
        if dictation.unavailable { return p.mutedForeground.color.opacity(0.6) }
        return p.mutedForeground.color
    }

    // MARK: Attachment chips

    /// Removable chips for the selected tabs and files, between the header and
    /// the results list.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachedTabIDs, id: \.self) { id in
                    if let tab = store.tabs.first(where: { $0.id == id }) {
                        AttachmentChip(label: tab.displayTitle,
                                       faviconURL: tab.faviconURL,
                                       page: tab.displayURL,
                                       systemIcon: nil) {
                            attachedTabIDs.removeAll { $0 == id }
                        }
                    }
                }
                ForEach(attachedFiles, id: \.self) { url in
                    AttachmentChip(label: url.lastPathComponent,
                                   faviconURL: nil,
                                   page: nil,
                                   systemIcon: "doc") {
                        attachedFiles.removeAll { $0 == url }
                    }
                }
            }
            .padding(.horizontal, LauncherMetrics.headerPadding)
            .padding(.bottom, 10)
        }
    }

    // MARK: Attachment handling

    /// Open an NSOpenPanel for text / markdown / json / csv / pdf / source files.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let exts = ["txt", "md", "markdown", "text", "json", "csv", "pdf",
                    "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs",
                    "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs",
                    "php", "html", "css", "scss", "xml", "yaml", "yml", "toml",
                    "ini", "sh", "sql", "r", "lua", "pl"]
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where !attachedFiles.contains(url) {
                attachedFiles.append(url)
            }
        }
    }

    /// Submit the typed query together with the selected tabs/files as Ask-Millie
    /// context. Gathering is async (tab text + file reads), so it runs after the
    /// launcher dismisses.
    private func submitWithAttachments() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabs = attachedTabIDs.compactMap { id in store.tabs.first { $0.id == id } }
        let files = attachedFiles
        let summary = Self.attachmentSummary(tabCount: tabs.count, fileCount: files.count)
        dictation.stop()
        store.dismissLauncher()
        Task { @MainActor in
            let context = await Self.gatherContext(tabs: tabs, files: files)
            store.askMillieWithContext(question: q, title: summary, context: context)
        }
    }

    /// Build the labeled, budget-capped context string from the attachments.
    private static func gatherContext(tabs: [BrowserTab], files: [URL]) async -> String {
        let perItemCap = 6000
        let totalCap = 16000
        var parts: [String] = []
        var total = 0
        func add(_ s: String) {
            guard total < totalCap else { return }
            let chunk = String(s.prefix(totalCap - total))
            parts.append(chunk)
            total += chunk.count
        }
        for tab in tabs {
            let raw = (try? await tab.evaluateJavaScript(
                "document.body ? document.body.innerText : ''")) as? String ?? ""
            let text = String(raw.prefix(perItemCap))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            add("Tab — \(tab.displayTitle) (\(tab.displayURL)):\n\(text)\n\n")
        }
        for url in files {
            guard let raw = readFileText(url) else { continue }
            let text = String(raw.prefix(perItemCap))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            add("File — \(url.lastPathComponent):\n\(text)\n\n")
        }
        return parts.joined()
    }

    /// Read a file as text: PDFs via PDFKit, everything else as UTF-8. Returns
    /// nil for anything unreadable (skipped).
    private static func readFileText(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func attachmentSummary(tabCount: Int, fileCount: Int) -> String {
        var bits: [String] = []
        if tabCount > 0 { bits.append("\(tabCount) tab\(tabCount == 1 ? "" : "s")") }
        if fileCount > 0 { bits.append("\(fileCount) file\(fileCount == 1 ? "" : "s")") }
        return bits.isEmpty ? "attachments" : bits.joined(separator: " + ")
    }

    /// The results area hugs its content — a few rows keep the panel small,
    /// and it grows (up to the visible cap, then scrolls) as results appear
    /// while typing. Shrinks at rest to just the recent-tabs list.
    private var resultsHeight: CGFloat {
        let rows = min(items.count, LauncherMetrics.visibleResultCount)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * LauncherMetrics.rowHeight
            + CGFloat(rows - 1) * LauncherMetrics.rowSpacing
            + LauncherMetrics.resultsPadding * 2
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: LauncherMetrics.rowSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    LauncherRow(item: item, isHighlighted: idx == highlighted, scheme: scheme) {
                        activate(item)
                    }
                    .onHover { if $0 { highlighted = idx } }
                }
            }
            .padding(.horizontal, LauncherMetrics.resultsPadding)
            .padding(.vertical, LauncherMetrics.resultsPadding)
        }
        .frame(height: resultsHeight)
        .scrollIndicators(.never)
        .animation(Motion.snappy, value: resultsHeight)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }

    private func commit() {
        // Attachments present → route to Ask Millie with the gathered context
        // instead of the normal open/search flow.
        if hasAttachments {
            submitWithAttachments()
            return
        }
        if siteSearch != nil {
            commitSiteSearch()
            return
        }
        if items.indices.contains(highlighted) {
            activate(items[highlighted])
        } else {
            store.launcherOpen(query)
        }
    }

    // MARK: Inline autocomplete

    /// → pressed with a ghost completion showing: fold it into the query so the
    /// field now holds the full host (completion stops re-firing because the
    /// typed text already equals the host).
    private func acceptInlineCompletion(_ host: String) {
        query = host
        highlighted = 0
    }

    /// Enter pressed with a ghost completion showing: open the completed host
    /// directly as a URL (Spotlight/omnibox behavior).
    private func acceptInlineCompletionAndOpen(_ host: String) {
        store.launcherOpen(url: URLInterpreter.resolve(host, settings: store.settings))
    }

    // MARK: Site search (chip)

    private func activateSiteSearch(_ provider: SiteSearch) {
        withAnimation(Motion.snappy) { siteSearch = provider }
        query = ""
        highlighted = 0
    }

    private func commitSiteSearch() {
        guard let ss = siteSearch else { return }
        store.launcherOpen(url: ss.url(for: query))
        siteSearch = nil
    }

    /// Tab pressed in the field: lock in a matching keyword as a chip.
    private func handleTab() -> Bool {
        guard siteSearch == nil, let match = SiteSearch.match(query) else { return false }
        activateSiteSearch(match)
        return true
    }

    /// Backspace in an empty field: dissolve the chip back into its keyword.
    private func handleEmptyDelete() -> Bool {
        guard let ss = siteSearch else { return false }
        withAnimation(Motion.snappy) { siteSearch = nil }
        query = ss.id
        return true
    }

    /// Space after a bare keyword activates the chip too ("youtube ␣").
    private func autoActivateOnSpace(_ text: String) {
        guard siteSearch == nil, text.hasSuffix(" ") else { return }
        if let match = SiteSearch.match(text) {
            activateSiteSearch(match)
        }
    }

    private func activate(_ item: LauncherItem) {
        if let run = item.run {
            run()
        } else if let id = item.tabID {
            store.launcherSwitch(to: id)
        } else {
            store.launcherOpen(url: item.url)
        }
    }
}

private enum LauncherMetrics {
    static let cardWidth: CGFloat = 720
    static let horizontalPadding: CGFloat = 24
    static let headerHeight: CGFloat = 64
    static let headerPadding: CGFloat = 20
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 2
    static let resultsPadding: CGFloat = 10
    static let rowInnerPadding: CGFloat = 12
    static let rowCorner: CGFloat = 10
    /// Footer control (pill / button) height, and the bar that holds them.
    static let footerControl: CGFloat = 30
    static let footerHeight: CGFloat = 56
    static let visibleResultCount = 7
    static let maxResultsHeight: CGFloat = {
        let rows = CGFloat(visibleResultCount)
        let gaps = CGFloat(max(visibleResultCount - 1, 0))
        return rows * rowHeight + gaps * rowSpacing + resultsPadding * 2
    }()
    static let cornerRadius: CGFloat = Radius.popover
    /// Fraction of the window height at which the card's top edge is pinned.
    static let topFraction: CGFloat = 0.24

    /// The highlighted-row wash — a touch of light over the card surface so the
    /// active result reads clearly without a heavy accent tint.
    static func highlightFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.05)
    }

    /// Solid accent for the highlighted result (Spotlight/Dia-style blue).
    static let accent = Color(.sRGB, red: 0.243, green: 0.416, blue: 0.882, opacity: 1)
}

/// AppKit-backed launcher input. SwiftUI `@FocusState` is timing-sensitive when
/// hosted above Chromium's native view; the field editor here can claim first
/// responder directly on each presentation and keep normal palette keys working.
private struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let selectAllOnFocus: Bool
    let foregroundColor: NSColor
    let insertionColor: NSColor
    /// Color of the greyed inline-completion ("ghost") text.
    var completionColor: NSColor = .secondaryLabelColor
    /// Full host to inline-complete to (e.g. "cnn.com") when it extends `text`.
    /// `nil` disables inline completion.
    var inlineCompletion: String? = nil
    let onMove: (Int) -> Void
    let onEscape: () -> Void
    let onSubmit: () -> Void
    /// Tab pressed — return true when handled (site-search chip activation).
    var onTab: () -> Bool = { false }
    /// Backspace in an empty field — return true when handled (chip removal).
    var onEmptyDelete: () -> Bool = { false }
    /// → pressed with a ghost completion visible: accept it into the query.
    var onAcceptInline: (String) -> Void = { _ in }
    /// Enter pressed with a ghost completion visible: accept + open directly.
    var onAcceptInlineSubmit: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.isEditable = true
        field.isSelectable = true
        field.font = Self.font
        field.textColor = foregroundColor
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byClipping
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Don't clobber the field while it's displaying a valid ghost completion
        // of `text` (that string legitimately differs from `text`).
        let showingCompletion = inlineCompletion.map {
            field.stringValue.lowercased() == $0.lowercased()
        } ?? false
        if field.stringValue != text, !showingCompletion {
            field.stringValue = text
        }
        field.font = Self.font
        field.textColor = foregroundColor
        field.backgroundColor = .clear
        context.coordinator.focusIfNeeded(field)
        context.coordinator.applyInlineCompletion(field)
    }

    private static var font: NSFont {
        // System font at a true regular weight: the Söhne family's lightest
        // available face still renders heavy at this size, so use the system
        // face for a clean, light omnibox input.
        .systemFont(ofSize: 15, weight: .regular)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchField
        private var appliedFocusRequest: Int?
        /// True while we're mutating the field editor programmatically to show a
        /// ghost completion — so `controlTextDidChange` ignores that mutation.
        private var applyingCompletion = false
        /// Set when the user just deleted; suppresses one completion pass so a
        /// backspace can actually remove characters instead of being re-filled.
        private var suppressCompletion = false

        init(_ parent: LauncherSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !applyingCompletion,
                  let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Enter accepts a visible ghost completion and opens it directly.
                if completionSelectionPresent(textView) {
                    parent.onAcceptInlineSubmit(textView.string)
                    return true
                }
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                // Navigating the list dismisses the ghost so Enter targets the
                // highlighted row, not the completion.
                _ = dismissCompletion(textView)
                parent.onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                _ = dismissCompletion(textView)
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveToEndOfLine(_:)):
                // → accepts the ghost completion into the query.
                if completionSelectionPresent(textView) {
                    let full = textView.string
                    textView.setSelectedRange(
                        NSRange(location: (full as NSString).length, length: 0))
                    suppressCompletion = true
                    parent.onAcceptInline(full)
                    return true
                }
                return false
            case #selector(NSResponder.moveLeft(_:)):
                // ← restores the typed text (drops the ghost) rather than
                // leaving the caret stranded inside the completion.
                if dismissCompletion(textView) { return true }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.string.isEmpty { return parent.onEmptyDelete() }
                // User is deleting — don't re-complete on the resulting pass.
                suppressCompletion = true
                return false
            case #selector(NSResponder.deleteForward(_:)):
                suppressCompletion = true
                return false
            default:
                return false
            }
        }

        // MARK: Inline completion

        /// Whether the field editor currently shows our trailing ghost selection
        /// (a selection that begins exactly after the typed text and runs to the
        /// end). Used to decide if →/Enter should accept it.
        private func completionSelectionPresent(_ tv: NSTextView) -> Bool {
            let sel = tv.selectedRange()
            let typedLen = (parent.text as NSString).length
            let total = (tv.string as NSString).length
            return sel.length > 0
                && sel.location == typedLen
                && sel.location + sel.length == total
                && total > typedLen
        }

        /// Replace the field contents with the typed text, caret at the end.
        /// Returns true if a ghost completion was actually present.
        @discardableResult
        private func dismissCompletion(_ tv: NSTextView) -> Bool {
            guard completionSelectionPresent(tv) else { return false }
            let typed = parent.text
            applyingCompletion = true
            tv.string = typed
            tv.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
            applyingCompletion = false
            suppressCompletion = true
            return true
        }

        /// Apply the inline ghost completion to the field, if one is available
        /// and the field currently shows exactly the typed text with the caret
        /// at the end. Idempotent and safe to call on every update pass.
        func applyInlineCompletion(_ field: NSTextField) {
            if suppressCompletion { suppressCompletion = false; return }
            guard let comp = parent.inlineCompletion,
                  let editor = field.currentEditor() as? NSTextView else { return }
            let typed = parent.text
            let typedLen = (typed as NSString).length
            guard typedLen > 0,
                  (comp as NSString).length > typedLen,
                  comp.lowercased().hasPrefix(typed.lowercased()),
                  editor.string == typed else { return }
            let sel = editor.selectedRange()
            guard sel.length == 0, sel.location == typedLen else { return }

            // Preserve the user's typed casing, append the remaining host chars.
            let suffix = String(comp.dropFirst(typed.count))
            let display = typed + suffix
            applyingCompletion = true
            editor.string = display
            editor.selectedTextAttributes = [
                .backgroundColor: parent.completionColor.withAlphaComponent(0.18),
                .foregroundColor: parent.completionColor
            ]
            editor.setSelectedRange(
                NSRange(location: typedLen, length: (display as NSString).length - typedLen))
            applyInsertionColor(field)
            applyingCompletion = false
        }

        func focusIfNeeded(_ field: NSTextField) {
            let request = parent.focusRequest
            guard appliedFocusRequest != request else {
                applyInsertionColor(field)
                return
            }

            applyFocus(field, request: request)
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                self.applyFocus(field, request: request)
                DispatchQueue.main.async { [weak self, weak field] in
                    guard let self, let field else { return }
                    self.applyFocus(field, request: request)
                }
            }
        }

        private func applyFocus(_ field: NSTextField, request: Int) {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            applyInsertionColor(field)

            guard field.currentEditor() != nil || window.firstResponder === field else {
                return
            }
            if parent.selectAllOnFocus {
                field.currentEditor()?.selectAll(nil)
            }
            appliedFocusRequest = request
        }

        private func applyInsertionColor(_ field: NSTextField) {
            (field.currentEditor() as? NSTextView)?.insertionPointColor = parent.insertionColor
        }
    }
}

/// One launcher result: either an open tab (offers "Switch to Tab") or a history
/// entry (opens in a fresh tab).
private struct LauncherItem: Identifiable {
    let id: String
    let title: String
    let url: String
    let faviconURL: String?
    /// Non-nil when this result is an already-open tab.
    let tabID: BrowserTab.ID?
    /// Trailing affordance label ("Switch to Tab", "Open", "Search").
    let action: String
    /// For command/search results: the SF Symbol to show in place of a favicon.
    var iconSystemName: String? = nil
    /// Muted trailing host/subtitle ("cnn.com", "cnn.co…/path"), nil to hide.
    var subtitle: String? = nil
    /// For command results: the action to run on activation. Command closures
    /// dismiss the launcher themselves.
    var run: (() -> Void)? = nil

    /// The bare host this row could inline-complete to (addressy rows only).
    /// `nil` for commands, search suggestions, and deep links (with a path).
    var completionHost: String? {
        // Site predictions carry the domain as their title.
        if id.hasPrefix("site-") { return title }
        guard iconSystemName == nil,
              let comps = URLComponents(string: url),
              let host = comps.host,
              comps.path.isEmpty || comps.path == "/" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Pretty "host + path" for the trailing subtitle; scheme and "www." are
    /// dropped and a bare "/" path is omitted.
    static func prettyURL(_ raw: String) -> String? {
        guard let comps = URLComponents(string: raw), let host = comps.host else { return nil }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = comps.path
        return (path.isEmpty || path == "/") ? h : h + path
    }

    static func build(query: String,
                      store: BrowserStore,
                      suggestions: [String] = []) -> [LauncherItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var out: [LauncherItem] = []

        if !rawQuery.isEmpty {
            let resolved = URLInterpreter.resolve(rawQuery, settings: store.settings)
            let isAddress = URLInterpreter.resolvesAsAddress(rawQuery)
            seen.insert(resolved)
            // Stable id (not keyed on the resolved URL) so the row persists
            // across keystrokes instead of being torn down on every character.
            out.append(LauncherItem(id: isAddress ? "direct-address" : "direct-search",
                                    title: isAddress ? rawQuery : rawQuery,
                                    url: resolved,
                                    faviconURL: nil,
                                    tabID: nil,
                                    action: isAddress ? "Open" : "Search",
                                    iconSystemName: isAddress ? nil : "magnifyingglass",
                                    subtitle: nil))
        }

        // Commands (actions), matched while typing — surfaced near the top.
        out.append(contentsOf: commands(query: q, store: store))

        // Open tabs: idle is an Arc-style MRU switcher — only tabs you've
        // actually visited (realized), most-recently-used first, capped at 4.
        // Restored-but-never-opened tabs are excluded (they'd otherwise crowd
        // the list with pages you never clicked). Typing matches across ALL
        // tabs. In address-bar mode the current tab is being edited, so
        // "Switch to" it is redundant — skip it.
        let candidateTabs: [BrowserTab] = q.isEmpty
            ? Array(store.tabs
                .filter { $0.hasRealized }
                .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
                .prefix(4))
            : store.tabs
        for tab in candidateTabs {
            if store.launcherEditsCurrentTab, tab.id == store.selectedTabID { continue }
            let match = q.isEmpty
                || tab.title.lowercased().contains(q)
                || tab.urlString.lowercased().contains(q)
            guard match else { continue }
            let key = tab.urlString.isEmpty ? "tab:\(tab.id)" : tab.urlString
            guard seen.insert(key).inserted else { continue }
            out.append(LauncherItem(id: "tab-\(tab.id)",
                                    title: tab.title,
                                    url: tab.displayURL,
                                    faviconURL: tab.faviconURL,
                                    tabID: tab.id,
                                    action: "Switch to Tab",
                                    subtitle: prettyURL(tab.displayURL)))
        }

        // History only while typing — idle stays compact (just the 4 recent
        // tabs). Typing brings back best-match suggestions.
        let history = q.isEmpty
            ? []
            : HistoryStore.shared.suggestions(for: q, limit: 8)
        for entry in history {
            guard seen.insert(entry.url).inserted else { continue }
            out.append(LauncherItem(id: "hist-\(entry.id)",
                                    title: entry.title.isEmpty ? entry.url : entry.title,
                                    url: entry.url,
                                    faviconURL: nil,
                                    tabID: nil,
                                    action: "Open",
                                    subtitle: prettyURL(entry.url)))
        }

        // Site prediction: guess likely domains from a curated top-sites list
        // (e.g. "cn" → cnn.com, cnbc.com…), so the type-ahead predicts sites
        // you've never visited — not just history. Ranked here, below your own
        // history/tabs, so real signal wins; these only fill open slots.
        if !q.isEmpty {
            for domain in TopDomains.matches(for: q, limit: 6) {
                let url = "https://\(domain)"
                guard seen.insert(url).inserted else { continue }
                out.append(LauncherItem(id: "site-\(domain)",
                                        title: domain,
                                        url: url,
                                        faviconURL: nil,
                                        tabID: nil,
                                        action: "Open"))
            }
        }

        // Live search suggestions (keyless Google suggest). Ranked last so a
        // user's own history/tabs and strong site matches win; these fill the
        // remaining slots up to the overall cap.
        if !rawQuery.isEmpty {
            let rawLower = rawQuery.lowercased()
            for suggestion in suggestions {
                let s = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty, s.lowercased() != rawLower else { continue }
                let key = "suggest:\(s.lowercased())"
                guard seen.insert(key).inserted else { continue }
                out.append(LauncherItem(id: key,
                                        title: s,
                                        url: store.settings.searchURL(for: s),
                                        faviconURL: nil,
                                        tabID: nil,
                                        action: "Search",
                                        iconSystemName: "magnifyingglass",
                                        subtitle: nil))
            }
        }

        return Array(out.prefix(8))
    }

    /// Build the matching command (action) results for the current query.
    private static func commands(query q: String, store: BrowserStore) -> [LauncherItem] {
        guard !q.isEmpty else { return [] }
        struct Cmd { let title: String; let icon: String; let keywords: String; let run: () -> Void }
        var defs: [Cmd] = [
            Cmd(title: "New Tab", icon: "plus.square", keywords: "new tab open") {
                store.dismissLauncher(); store.newTab() },
            Cmd(title: "New Split", icon: "rectangle.split.2x1", keywords: "split view side") {
                store.dismissLauncher(); store.newSplit() },
            Cmd(title: "Reader View", icon: "doc.plaintext", keywords: "reader read article") {
                store.dismissLauncher(); store.toggleReader() },
            Cmd(title: "Capture Region", icon: "camera.viewfinder", keywords: "screenshot capture region snip crop") {
                store.dismissLauncher(); store.startRegionCapture() },
            Cmd(title: "Capture Visible Tab", icon: "camera", keywords: "screenshot capture visible page") {
                store.dismissLauncher(); store.captureVisibleArea() },
            Cmd(title: "Capture Full Page", icon: "doc.viewfinder", keywords: "screenshot capture full page long scrolling") {
                store.dismissLauncher(); store.captureFullPage() },
            Cmd(title: "Share Page…", icon: "square.and.arrow.up", keywords: "share airdrop mail messages send") {
                store.dismissLauncher(); store.shareCurrentPage() },
            Cmd(title: "Boost This Site", icon: "wand.and.stars", keywords: "boost custom css js") {
                store.dismissLauncher(); store.presentBoostEditor() },
            Cmd(title: "Zap an Element", icon: "scope", keywords: "zap hide remove element") {
                store.dismissLauncher(); store.startZapMode() },
            Cmd(title: "Peek a Link", icon: "eye", keywords: "peek preview clipboard little arc") {
                store.dismissLauncher(); store.peekFromClipboardOrCurrent() },
            Cmd(title: "Sleep Background Tabs", icon: "moon.zzz", keywords: "sleep memory tabs free") {
                store.dismissLauncher(); store.sleepBackgroundTabs() },
            Cmd(title: "Reopen Closed Tab", icon: "arrow.uturn.left", keywords: "reopen closed restore tab") {
                store.dismissLauncher(); store.reopenClosedTab() },
            Cmd(title: "Find in Page", icon: "magnifyingglass", keywords: "find search page text") {
                store.dismissLauncher(); store.showFindBar() },
            Cmd(title: "Toggle Sidebar", icon: "sidebar.right", keywords: "sidebar hide show") {
                store.dismissLauncher(); store.toggleSidebar() },
            Cmd(title: "Settings", icon: "gearshape", keywords: "settings preferences options") {
                store.dismissLauncher(); store.settingsVisible = true },
            Cmd(title: "New Space", icon: "square.grid.2x2", keywords: "space context new create") {
                store.dismissLauncher(); store.contextCreationVisible = true }
        ]
        if store.settings.aiIntegrationEnabled {
            defs.append(Cmd(title: "Open Assistant", icon: "sparkles", keywords: "ai assistant codex chat ask") {
                store.dismissLauncher(); store.openAIPanel()
            })
        }
        for ctx in store.contexts where ctx.id != store.activeContextID {
            defs.append(Cmd(title: "Switch to \(ctx.name)",
                            icon: "arrow.right.circle",
                            keywords: "space context switch go \(ctx.name)") {
                store.dismissLauncher(); store.switchContext(to: ctx.id)
            })
        }

        let needles = q.split(separator: " ").map(String.init)
        return defs.filter { cmd in
            let hay = (cmd.title + " " + cmd.keywords).lowercased()
            return needles.allSatisfy { hay.contains($0) }
        }
        .prefix(5)
        .map { cmd in
            LauncherItem(id: "cmd-\(cmd.title)", title: cmd.title, url: "",
                         faviconURL: nil, tabID: nil, action: "Run",
                         iconSystemName: cmd.icon, run: cmd.run)
        }
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let isHighlighted: Bool
    let scheme: ColorScheme
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon

                Text(item.title.isEmpty ? item.url : item.title)
                    .font(Typography.ui(15, weight: .medium))
                    .foregroundStyle(p.foreground.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 12)

                if let sub = item.subtitle, !sub.isEmpty {
                    HStack(spacing: 5) {
                        Text("—")
                            .foregroundStyle(p.mutedForeground.color.opacity(0.45))
                        Text(sub)
                            .foregroundStyle(p.mutedForeground.color.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(Typography.ui(Typography.base, weight: .regular))
                    .frame(maxWidth: 280, alignment: .trailing)
                    .layoutPriority(0)
                }
            }
            .padding(.horizontal, LauncherMetrics.rowInnerPadding)
            .frame(height: LauncherMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: LauncherMetrics.rowCorner, style: .continuous)
                    .fill(isHighlighted ? LauncherMetrics.highlightFill(scheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.state, value: isHighlighted)
    }

    /// Leading glyph (20pt): a command/search SF symbol, or the page favicon
    /// (which falls back to a globe for sites without a decoded icon).
    @ViewBuilder private var icon: some View {
        Group {
            if let sys = item.iconSystemName {
                Icon(name: sys, size: 18, weight: .medium)
                    .foregroundStyle(p.mutedForeground.color)
            } else {
                Favicon(icon: item.faviconURL, page: item.url, size: 20)
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Attachment picker + chips

/// Popover for "Add tabs or files": a multi-select list of open tabs plus a
/// file chooser. Selections flow back through the bound arrays and render as
/// chips in the launcher.
private struct AttachPicker: View {
    @ObservedObject var store: BrowserStore
    @Binding var attachedTabIDs: [UUID]
    @Binding var attachedFiles: [URL]
    let chooseFiles: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add context")
                .font(Typography.ui(13, weight: .semibold))
                .foregroundStyle(p.popoverForeground.color)

            if store.tabs.isEmpty {
                Text("No open tabs")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.tabs) { tab in
                            tabRow(tab)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            Divider().opacity(0.5)

            Button(action: chooseFiles) {
                HStack(spacing: 7) {
                    Icon(name: "folder", size: 14, weight: .medium)
                    Text("Choose files…")
                        .font(Typography.ui(Typography.base, weight: .medium))
                }
                .foregroundStyle(p.foreground.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
        .background(p.popover.color)
    }

    @ViewBuilder private func tabRow(_ tab: BrowserTab) -> some View {
        let selected = attachedTabIDs.contains(tab.id)
        Button {
            if selected {
                attachedTabIDs.removeAll { $0 == tab.id }
            } else {
                attachedTabIDs.append(tab.id)
            }
        } label: {
            HStack(spacing: 9) {
                Favicon(icon: tab.faviconURL, page: tab.displayURL, size: 16)
                    .frame(width: 18, height: 18)
                Text(tab.displayTitle)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.popoverForeground.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Icon(name: selected ? "checkmark.circle.fill" : "circle",
                     size: 15, weight: .medium)
                    .foregroundStyle(selected ? LauncherMetrics.accent
                                              : p.mutedForeground.color.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(selected ? LauncherMetrics.accent.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// A compact removable chip for one attached tab or file.
private struct AttachmentChip: View {
    let label: String
    let faviconURL: String?
    let page: String?
    let systemIcon: String?
    let onRemove: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 5) {
            if let systemIcon {
                Icon(name: systemIcon, size: 11, weight: .medium)
                    .foregroundStyle(p.mutedForeground.color)
            } else {
                Favicon(icon: faviconURL, page: page ?? "", size: 13)
                    .frame(width: 13, height: 13)
            }
            Text(label)
                .font(Typography.ui(Typography.label, weight: .medium))
                .foregroundStyle(p.foreground.color)
                .lineLimit(1)
                .frame(maxWidth: 140)
            Button(action: onRemove) {
                Icon(name: "xmark", size: 9, weight: .bold)
                    .foregroundStyle(p.mutedForeground.color)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(p.foreground.color.opacity(0.06)))
        .overlay(Capsule().strokeBorder(p.border.color.opacity(0.4), lineWidth: 1))
    }
}
