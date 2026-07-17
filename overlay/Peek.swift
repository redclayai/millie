import SwiftUI
import AppKit

// MARK: - Store coordination

extension BrowserStore {
    /// Open a URL in a transient Peek overlay (Little Arc-style) without adding
    /// it to any space.
    func peek(url rawURL: String) {
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
        let tab = BrowserTab(url: target, title: "Peek")
        // New-tab links opened FROM a peek stay in the peek (Little Arc style):
        // the overlay just shows the next page instead of spawning real tabs.
        tab.onRequestNewTab = { [weak self] u in self?.peek(url: u) }
        tab.realize()
        tab.markAccessed()
        if let existing = peekTab { existing.close() }
        withAnimation(Motion.reveal) { peekTab = tab }
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
        withAnimation(Motion.reveal) { peekTab = nil }
        // Defer the WebContents teardown to the next runloop tick. ESC can
        // arrive *through the peek's own web view*; closing it synchronously
        // here destroys the RenderWidgetHostView mid-key-event-dispatch, which
        // re-enters Chromium/AppKit and freezes the main thread. Dropping the
        // overlay now and closing next tick lets the event finish first.
        DispatchQueue.main.async { tab.close() }
    }

    /// Promote the peeked page into a real tab in the active context. Mount it
    /// as a real tab FIRST, then clear the overlay — so the same web view hands
    /// off to the tab strip with no unparented gap or teardown flash.
    func promotePeek() {
        guard let tab = peekTab else { return }
        tab.onMetadataChanged = { [weak self] _ in self?.scheduleSessionSave() }
        tabs.append(tab)
        addToActiveContext(tab.id)
        selectTab(tab.id)
        peekTab = nil
        scheduleSessionSave()
    }

    /// Promote the peeked page and open it in a split beside the tab that was
    /// active when the Peek was raised.
    func promotePeekToSplit() {
        guard let tab = peekTab else { return }
        let previous = selectedTabID
        tab.onMetadataChanged = { [weak self] _ in self?.scheduleSessionSave() }
        tabs.append(tab)
        addToActiveContext(tab.id)
        selectTab(tab.id)
        if let previous, previous != tab.id {
            splitWith(previous, side: .right)
        }
        peekTab = nil
        scheduleSessionSave()
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

                PeekCard(store: store, tab: tab)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(Motion.reveal, value: store.peekTab != nil)
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
            let width = min(geo.size.width - 120, 1500)
            let height = min(geo.size.height - 130, 1120)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
private struct PeekWebHost: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = cornerRadius > 0
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let view = tab.realize()
        if view.superview !== nsView {
            view.removeFromSuperview()
            view.frame = nsView.bounds
            view.autoresizingMask = [.width, .height]
            nsView.addSubview(view)
        }
        view.isHidden = false
        view.setWebWindowVisible(true)
        view.setPageHidden(false)
    }
}
