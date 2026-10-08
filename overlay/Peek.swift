import SwiftUI
import AppKit

// MARK: - Store coordination

extension BrowserStore {
    /// Open a URL in a transient Peek overlay (Little Arc-style) without adding
    /// it to any space.
    func peek(url rawURL: String, profileKey: String? = nil) {
        let resolved = URLInterpreter.resolve(rawURL, settings: settings)
        // about:blank is allowed: it's the initial commit of a window.open the
        // Peek will adopt, with the real navigation following inside it.
        let isBlank = resolved == "about:blank"
        if !isBlank, BrowserURLPolicy.isPrivilegedURL(resolved),
           !confirmPrivilegedNavigation(resolved, source: "Peek") {
            ToastCenter.shared.show("Blocked internal URL", icon: "lock", style: .warning)
            return
        }
        guard isBlank || BrowserURLPolicy.isWebURL(resolved)
                || BrowserURLPolicy.isPrivilegedURL(resolved) else {
            ToastCenter.shared.show("Nothing to peek", icon: "eye", style: .warning)
            return
        }
        let target = MoriURLRewriter.rewrite(resolved)
        // Match the peek tab's profile to the source (or active Space's), so the
        // engine adopts the waiting orphan WebContents for window.open /
        // target=_blank links (adoption is profile-keyed). A mismatch here left
        // the real navigation stranded on the un-adopted orphan and showed a
        // blank about:blank tab titled "Peek" — which then promoted blank.
        let resolvedProfile = profileKey ?? selectedTab?.profileKey ?? activeProfileKey
        let tab = BrowserTab(url: target, title: "Peek", profileKey: resolvedProfile)
        // New-tab links opened FROM a peek stay in the peek (Little Arc style):
        // the overlay just shows the next page instead of spawning real tabs.
        tab.onRequestNewTab = { [weak self] u in self?.peek(url: u, profileKey: resolvedProfile) }
        // An OAuth "you can close this tab" popup (opened via window.open, so it
        // landed in the Peek) finishes by calling window.close(). Honor it: the
        // engine tears down the WebContents and reports back here, so the Peek
        // dismisses itself instead of stranding a dead card the user can't exit.
        tab.onEngineClose = { [weak self, weak tab] in
            guard let self, let tab, self.peekTab === tab else { return }
            self.closePeek()
        }
        tab.realize()
        tab.markAccessed()
        // Defer closing the previous peek to the next runloop tick. peek() can
        // be reached synchronously from inside a TabStripModel observer
        // (MoriTabStripBridge::OnTabStripModelChanged, fired mid-insert when a
        // page does window.open / target=_blank). Closing a tab there calls
        // TabStripModel::CloseWebContentsAt while the strip is still mutating,
        // which trips Chromium's ValidateNotReentrant CHECK and hard-crashes.
        // Dropping the reference now and closing next tick keeps the teardown
        // outside the observer — same reason closePeek() defers its close.
        if let existing = peekTab {
            DispatchQueue.main.async { existing.close() }
        }
        withAnimation(Motion.snappy) { peekTab = tab }
        // Replenish the spare renderer for the next Peek in this Space.
        MoriPrivacy.warmupSpareRenderer()
    }

    /// Peek the clipboard's URL if it holds one, else the current page — the
    /// classic "I just copied a link, let me glance at it" flow.
    func peekFromClipboardOrCurrent() {
        if let clip = NSPasteboard.general.string(forType: .string),
           URLInterpreter.resolvesAsAddress(clip) {
            peek(url: clip)
            return
        }
        if let url = selectedTab?.urlString, !url.isEmpty, url != "about:blank" {
            peek(url: url)
        } else {
            ToastCenter.shared.show("Nothing to peek", icon: "eye", style: .warning)
        }
    }

    func closePeek() {
        guard let tab = peekTab else { return }
        withAnimation(Motion.snappy) { peekTab = nil }
        // Defer the WebContents teardown to the next runloop tick. ESC can
        // arrive *through the peek's own web view*; closing it synchronously
        // here destroys the RenderWidgetHostView mid-key-event-dispatch, which
        // re-enters Chromium/AppKit and freezes the main thread. Dropping the
        // overlay now and closing next tick lets the event finish first.
        DispatchQueue.main.async { tab.close() }
    }

    /// Promote the peeked page into a real tab in the active context.
    ///
    /// This opens the peeked URL as a FRESH tab and closes the Peek, rather than
    /// reparenting the Peek's live web view into the tab strip. Reparenting the
    /// live CEF view left it rendering black in the new tab (its compositor
    /// wouldn't repaint until the user tabbed away and back — no visibility /
    /// resize nudge reliably forced it). A freshly-created tab always renders
    /// (it's the same path every other tab uses); the only cost is the promoted
    /// page reloads, which is an acceptable trade for it actually showing.
    func promotePeek() {
        guard let tab = peekTab else { return }
        let url = promotableURL(for: tab)
        closePeek()
        focusPromotedTab(newTab(url: url, select: true))
    }

    /// Promote the peeked page and open it in a split beside the tab that was
    /// active when the Peek was raised.
    func promotePeekToSplit() {
        guard let tab = peekTab else { return }
        let previous = selectedTabID
        let url = promotableURL(for: tab)
        closePeek()
        let promoted = newTab(url: url, select: true)
        if let previous, previous != promoted.id {
            splitWith(previous, side: .right)
        }
        focusPromotedTab(promoted)
    }

    /// After promoting a Peek, force keyboard focus onto the new tab so its
    /// fresh CEF view actually composites (otherwise it shows blank). Two panels
    /// each break the normal paint nudge (`focusBrowser`) differently:
    ///   • Web panel — lives in its own child window; if it held key, focusBrowser
    ///     refuses to steal key from another window, so re-key the main window.
    ///   • AI panel — its SwiftUI composer holds text-input first responder, which
    ///     suppresses the auto-focus paint nudge (and would re-steal it); release
    ///     `aiInputFocused` so the composer resigns and the tab can take focus.
    /// Deferred (twice) so the tab's view is mounted in the window first.
    private func focusPromotedTab(_ tab: BrowserTab) {
        aiInputFocused = false
        let nudge: () -> Void = { [weak self, weak tab] in
            guard let tab, tab.hasRealized else { return }
            self?.aiInputFocused = false
            let view = tab.browserView
            view.window?.makeKeyAndOrderFront(nil)
            view.focusBrowser()
        }
        DispatchQueue.main.async(execute: nudge)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: nudge)
    }

    /// The URL to open when promoting a Peek — nil (new-tab page) if the peek
    /// never navigated past about:blank.
    private func promotableURL(for tab: BrowserTab) -> String? {
        let u = tab.urlString
        return (u.isEmpty || u == "about:blank") ? nil : u
    }
}

// MARK: - Overlay

/// The Peek overlay: a centered floating card hosting a single transient tab,
/// with controls to promote it to a real tab or dismiss it.
struct PeekOverlay: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            if let tab = store.peekTab {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { store.closePeek() }
                    .transition(.opacity)

                // Fade only. A scale transition can stall at 0.96 (SwiftUI hosted in
                // Chromium) and leave the web page rasterized at a fractional
                // scale — soft, blurry text.
                PeekCard(store: store, tab: tab)
                    .transition(.opacity)
            }
        }
        .animation(Motion.snappy, value: store.peekTab != nil)
    }
}

private struct PeekCard: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            // Arc-style: a large floating card that nearly fills the window,
            // with a consistent margin. The controls sit ABOVE the card (not
            // over the page) so they never collide with the site's own chrome.
            // Snap size and origin to whole points so the web view never lands
            // on a half-pixel (which blurs text).
            let width = (min(geo.size.width - 120, 1500) / 2).rounded(.down) * 2
            let height = (min(geo.size.height - 130, 1120) / 2).rounded(.down) * 2
            let stackHeight = 28 + 8 + height
            let originX = ((geo.size.width - width) / 2).rounded(.down)
            let originY = ((geo.size.height - stackHeight) / 2).rounded(.down)
            VStack(alignment: .trailing, spacing: 8) {
                controls
                    .frame(width: width, alignment: .trailing)
                PeekWebHost(tab: tab, cornerRadius: Radius.window)
                    .frame(width: width, height: height)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                            .fill(p.card.color))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                            .strokeBorder(p.border.color.opacity(0.7), lineWidth: 1))
                    .elevation(.overlay, scheme)
            }
            .padding(.leading, originX)
            .padding(.top, originY)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            control("xmark", "Close (Esc)") { store.closePeek() }
            control("arrow.up.left.and.arrow.down.right", "Open in Space (⌘↩)") {
                store.promotePeek()
            }
            control("rectangle.split.2x1", "Open in Split View") {
                store.promotePeekToSplit()
            }
        }
    }

    private func control(_ icon: String, _ help: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 12, weight: .semibold)
                .foregroundStyle(p.foreground.color)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(p.border.color.opacity(0.5), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Hosts a single transient tab's live CEF view inside the Peek card.
/// Container for the Peek's live web view that forces a repaint after a resize
/// (e.g. window maximize) — the CEF compositor otherwise sometimes leaves the
/// peek blank at the new size. Debounced so a live drag kicks only on release.
private final class PeekHostView: NSView {
    private var repaintKick: DispatchWorkItem?
    private var activationObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A Peek opened from another app (Mail, Choosy handoff, …) mounts while
        // Millie is still in the background. On Chromium 152 the mount-time
        // kickCompositor (SynchronizeVisualProperties) no longer forces a frame
        // from a backgrounded window, so the card stays gray until a real resize
        // (the user maximizing). Re-kick when Millie actually comes to the front
        // — app activation and this window becoming key both cover the handoff.
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        activationObservers.removeAll()
        guard window != nil else { return }
        let kick: (Notification) -> Void = { [weak self] _ in self?.kickSubviews() }
        let nc = NotificationCenter.default
        activationObservers.append(
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main, using: kick))
        activationObservers.append(
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification,
                           object: window, queue: .main, using: kick))
    }

    deinit {
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func kickSubviews() {
        for sub in subviews where !sub.isHidden {
            guard let bv = sub as? MoriBrowserView else { continue }
            bv.kickCompositor()
            // 152 safety net: SynchronizeVisualProperties alone won't force a
            // frame without a real size delta (why maximizing fixes the gray
            // card). Nudge the view 1pt and restore next tick so the web view's
            // RenderWidgetHostView sees an actual resize and paints.
            let f = bv.frame
            bv.setFrameSize(NSSize(width: f.width - 1, height: f.height))
            DispatchQueue.main.async { bv.setFrameSize(f.size) }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        repaintKick?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.kickSubviews() }
        repaintKick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

private struct PeekWebHost: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let container = PeekHostView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = cornerRadius > 0
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let view = tab.realize()
        let justMounted = view.superview !== nsView
        if justMounted {
            view.removeFromSuperview()
            view.frame = nsView.bounds
            view.autoresizingMask = [.width, .height]
            nsView.addSubview(view)
        }
        view.isHidden = false
        view.setWebWindowVisible(true)
        view.setPageHidden(false)
        if justMounted {
            // Force the first frame. focusBrowser can't be relied on here: when
            // the peek is opened from another app (Mail, etc.) Millie isn't key,
            // so focusBrowser's key-steal guard skips the paint nudge and the CEF
            // view stays black until re-clicked. kickCompositor repaints without
            // needing focus. Two ticks cover the engine-attach race.
            DispatchQueue.main.async { [weak view] in view?.kickCompositor() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak view] in
                view?.kickCompositor()
            }
        }
    }
}
