import SwiftUI
import AppKit
import AVFoundation

// MARK: - Model

/// What the user right-clicked on in the page.
struct LinkImageContextTarget {
    var linkURL: String?
    var linkText: String = ""
    var imageURL: String?
    var selection: String = ""

    var hasContent: Bool { linkURL != nil || imageURL != nil }
}

/// A pending custom context menu: its target plus where to anchor it (top-left,
/// in the root view's coordinate space).
struct WebContextMenuRequest: Identifiable {
    let id = UUID()
    let target: LinkImageContextTarget
    let location: CGPoint
    /// The raw right-click point in window coordinates (AppKit, bottom-left
    /// origin). Used to drive Chromium's native copy/save-image at that point.
    let windowPoint: CGPoint
}

// MARK: - Page scripts

enum WebContextScripts {
    /// Installs a bubble-phase contextmenu listener that HONORS the page. It runs
    /// after the site's own handlers; if the page already handled the right-click
    /// (`defaultPrevented` — e.g. Google Docs/Sheets/Figma showing their own menu,
    /// or a site disabling the menu), Millie stays out of the way. Only when the
    /// page didn't handle it does Millie record the target + `preventDefault()` so
    /// its overlay menu takes over — including on bare page area, where Chrome's
    /// native menu wouldn't render in the non-Views window anyway.
    static let listener = """
    (() => {
      if (window.__moriCtxInstalled) return;
      window.__moriCtxInstalled = true;
      window.__moriCtxSeq = 0;
      const closestLink = (el) => {
        while (el && el.nodeType === 1) {
          if (el.tagName === 'A' && el.href) return el;
          el = el.parentElement;
        }
        return null;
      };
      const bgImage = (el) => {
        try {
          const s = getComputedStyle(el).backgroundImage;
          const m = s && s.match(/url\\(["']?(.*?)["']?\\)/);
          return m ? m[1] : '';
        } catch (e) { return ''; }
      };
      const imageFor = (el) => {
        let node = el;
        while (node && node.nodeType === 1) {
          if (node.tagName === 'IMG' && (node.currentSrc || node.src)) {
            return node.currentSrc || node.src;
          }
          node = node.parentElement;
        }
        return bgImage(el) || '';
      };
      document.addEventListener('contextmenu', (e) => {
        // Only real user right-clicks get Millie's menu. Sites (e.g. n8n's
        // canvas) dispatch their OWN synthetic contextmenu events to drive a
        // custom menu; those are untrusted (isTrusted === false) and must be
        // ignored — Chrome's native menu does the same — otherwise Millie's
        // menu pops over the site's.
        if (!e.isTrusted) return;
        // The page's own handlers already ran (bubble phase). If any of them
        // handled the right-click — showing a custom menu (Docs/Sheets/Figma)
        // or deliberately disabling it — the event is defaultPrevented; leave
        // it alone so the site's menu wins, exactly like Chrome does.
        if (e.defaultPrevented) return;
        const link = closestLink(e.target);
        const image = imageFor(e.target);
        const selection = String(window.getSelection ? getSelection() : '').trim();
        // The page didn't handle it — claim the click for Millie's overlay menu
        // and suppress the native menu (which wouldn't render in the non-Views
        // Mori window, so a plain-page right-click would otherwise show nothing).
        window.__moriCtx = {
          seq: ++window.__moriCtxSeq,
          link: link ? link.href : '',
          linkText: link ? (link.innerText || link.textContent || '').trim().slice(0, 140) : '',
          image: image || '',
          selection: selection
        };
        e.preventDefault();
      }, false);
    })();
    """

    /// Reads and clears the last captured target.
    static let read = """
    (() => { const c = window.__moriCtx; window.__moriCtx = null; return c || null; })();
    """
}

// MARK: - Store coordination & actions

extension BrowserStore {
    /// Handle a right-click anywhere in the window: if it landed on a page link
    /// or image, present Millie's custom menu at the cursor.
    func handleWebRightClick(_ event: NSEvent) {
        guard let tab = selectedTab, tab.hasRealized else { return }
        let window = event.window
        let locationInWindow = event.locationInWindow
        Task { @MainActor in
            // Poll for the page's contextmenu payload. The DOM `contextmenu`
            // event that stashes the link/image target can land a little after
            // the native right-mouse-down reaches us (renderer round-trip), so
            // give it up to ~340ms. The old 100ms window was too short: the
            // first click's payload arrived after the poll gave up and was only
            // read by the *next* click — the "have to right-click twice" bug.
            var found: LinkImageContextTarget?
            for _ in 0..<17 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if let target = await tab.readContextMenuTarget() {
                    found = target
                    break
                }
            }
            guard let target = found else { return }
            let height = window?.contentView?.bounds.height
                ?? window?.frame.height ?? 0
            let point = CGPoint(x: locationInWindow.x, y: height - locationInWindow.y)
            withAnimation(Motion.snappy) {
                self.contextMenu = WebContextMenuRequest(
                    target: target, location: point, windowPoint: locationInWindow)
            }
        }
    }

    func dismissWebContextMenu() {
        guard contextMenu != nil else { return }
        withAnimation(Motion.snappy) { contextMenu = nil }
    }

    // Link actions

    func ctxOpenLink(_ url: String, inBackground: Bool) {
        guard let safeURL = resolvePageDerivedNavigationURL(url, source: "A page link") else {
            dismissWebContextMenu()
            return
        }
        newTab(url: safeURL, select: !inBackground)
        dismissWebContextMenu()
    }

    /// Hand a non-web link (mailto:/tel:/…) to the OS's default app.
    func ctxOpenExternal(_ url: String) {
        dismissWebContextMenu()
        openExternalScheme(url)
    }

    func ctxPeekLink(_ url: String) {
        guard let safeURL = resolvePageDerivedNavigationURL(url, source: "A page link") else {
            dismissWebContextMenu()
            return
        }
        peek(url: safeURL)
        dismissWebContextMenu()
    }

    /// Open the link in a chosen space (creating the tab there and switching to it).
    func ctxOpenLink(_ url: String, inContext id: BrowserContext.ID) {
        guard let safeURL = resolvePageDerivedNavigationURL(url, source: "A page link") else {
            dismissWebContextMenu()
            return
        }
        let tab = newTab(url: safeURL, select: false)
        moveTab(tab.id, toContext: id, activate: true)
        dismissWebContextMenu()
    }

    // Image actions

    func ctxOpenImage(_ url: String) {
        guard let safeURL = resolvePageDerivedNavigationURL(url, source: "A page image") else {
            dismissWebContextMenu()
            return
        }
        newTab(url: safeURL, select: true)
        dismissWebContextMenu()
    }

    func ctxSaveImage(_ url: String) {
        let tab = selectedTab
        let point = contextMenu?.windowPoint ?? .zero
        dismissWebContextMenu()
        let ok = tab?.saveImage(url: url, at: point) ?? false
        ToastCenter.shared.show(ok ? "Saving image…" : "Couldn't save that image",
                                icon: ok ? "square.and.arrow.down" : "xmark",
                                style: ok ? .success : .warning)
    }

    func ctxCopyImage(_ url: String) {
        let tab = selectedTab
        let point = contextMenu?.windowPoint
        dismissWebContextMenu()
        if let point, tab?.copyImage(at: point) == true {
            ToastCenter.shared.show("Image copied", icon: "doc.on.doc", style: .success)
        } else {
            // Fall back to copying the address when there's no live image.
            copyToPasteboard(url)
            ToastCenter.shared.show("Copied image address", icon: "link", style: .success)
        }
    }

    func ctxSearchImage(_ url: String) {
        guard let explicitURL = BrowserURLPolicy.explicitURL(url),
              BrowserURLPolicy.isWebURL(explicitURL) else {
            dismissWebContextMenu()
            ToastCenter.shared.show("Blocked non-web image search", icon: "lock", style: .warning)
            return
        }
        let encoded = explicitURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? explicitURL
        newTab(url: "https://lens.google.com/uploadbyurl?url=\(encoded)", select: true)
        dismissWebContextMenu()
    }

    // Page navigation

    func ctxGoBack() { dismissWebContextMenu(); selectedTab?.goBack() }
    func ctxGoForward() { dismissWebContextMenu(); selectedTab?.goForward() }
    func ctxReload() { dismissWebContextMenu(); selectedTab?.reload() }

    /// View the current page's HTML source in a new tab (Chrome's "View Page
    /// Source" / ⌘⌥U). Chromium renders the built-in `view-source:` scheme.
    func ctxViewSource() {
        dismissWebContextMenu()
        guard let url = selectedTab?.urlString, url.hasPrefix("http") else { return }
        newTab(url: "view-source:" + url, select: true)
    }

    func ctxSearchText(_ text: String) {
        dismissWebContextMenu()
        newTab(url: BrowserSettings.shared.searchURL(for: text), select: true)
    }

    func ctxInspect() {
        let point = contextMenu?.windowPoint ?? .zero
        dismissWebContextMenu()
        selectedTab?.inspectElement(at: point)
    }

    // Shared

    func ctxCopy(_ string: String, message: String) {
        copyToPasteboard(string)
        ToastCenter.shared.show(message, icon: "doc.on.doc", style: .success)
        dismissWebContextMenu()
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    // Native-style extras — the useful items macOS's own menu offers, added to
    // Millie's menu so a right-click feels closer to the system menu without
    // the (Chromium) engine work to host the real native menu.

    /// The web-content view + the right-click point in its coordinate space,
    /// captured before the menu is dismissed (dismiss clears `windowPoint`).
    private func webAnchor() -> (NSView, CGPoint)? {
        guard let windowPoint = contextMenu?.windowPoint,
              let view = (selectedTab?.browserView.window ?? NSApp.keyWindow)?.contentView
        else { return nil }
        return (view, view.convert(windowPoint, from: nil))
    }

    /// macOS "Look Up" — the dictionary/definition popover for the selection.
    func ctxLookUp(_ text: String) {
        let anchor = webAnchor()
        dismissWebContextMenu()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let (view, point) = anchor else { return }
        view.showDefinition(for: NSAttributedString(string: trimmed), at: point)
    }

    /// Speak the selection aloud (toggles off if already speaking).
    func ctxSpeak(_ text: String) {
        dismissWebContextMenu()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ContextSpeech.shared.toggle(trimmed)
    }

    /// macOS Share sheet, anchored at the right-click point. `subject` is a URL
    /// (link/page → shared as a URL) or selected text (shared as a string).
    func ctxShare(_ subject: String) {
        let anchor = webAnchor()
        dismissWebContextMenu()
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let (view, point) = anchor else { return }
        let items: [Any]
        if let url = URL(string: trimmed), url.scheme != nil { items = [url] }
        else { items = [trimmed] }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: NSRect(origin: point, size: .zero),
                    of: view, preferredEdge: .minY)
    }
}

/// Minimal speak-selection helper (macOS "Start Speaking"). Second invocation
/// while speaking stops it, matching the system behavior.
final class ContextSpeech {
    static let shared = ContextSpeech()
    private let synth = AVSpeechSynthesizer()
    func toggle(_ text: String) {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        } else {
            synth.speak(AVSpeechUtterance(string: text))
        }
    }
}

// MARK: - Right-click catcher

/// Installs an app-local right-mouse-down monitor so Millie can intercept page
/// right-clicks. Passive: it always returns the event so chrome context menus
/// and the renderer still receive it.
struct WebRightClickCatcher: NSViewRepresentable {
    let store: BrowserStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(store: store)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.store = store
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        weak var store: BrowserStore?
        private var monitor: Any?

        func install(store: BrowserStore) {
            self.store = store
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                self?.store?.handleWebRightClick(event)
                return event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Overlay

struct WebContextMenuOverlay: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        GeometryReader { geo in
            if let request = store.contextMenu {
                ZStack(alignment: .topLeading) {
                    // Invisible catcher: a click anywhere dismisses.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { store.dismissWebContextMenu() }

                    WebContextMenuCard(store: store, target: request.target)
                        .modifier(MenuPlacement(point: request.location, bounds: geo.size))
                }
                .transition(.opacity)
            }
        }
    }
}

/// Positions the menu at the click point, clamped to stay fully on-screen.
private struct MenuPlacement: ViewModifier {
    let point: CGPoint
    let bounds: CGSize
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let x = min(max(8, point.x), max(8, bounds.width - size.width - 8))
        let y = min(max(8, point.y), max(8, bounds.height - size.height - 8))
        content
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { size = g.size }
                        .onChange(of: g.size) { _, s in size = s }
                }
            )
            .offset(x: x, y: y)
    }
}

private struct WebContextMenuCard: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: BrowserStore
    let target: LinkImageContextTarget
    @Environment(\.palette) private var p

    private enum Page { case main, spaces }
    @State private var page: Page = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch page {
            case .main: mainItems
            case .spaces: spaceItems
            }
        }
        .padding(5)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .fill(p.popover.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
        )
        .elevation(.popover, scheme)
    }

    @ViewBuilder
    private var mainItems: some View {
        if let link = target.linkURL, BrowserURLPolicy.isExternalHandlerScheme(link) {
            externalLinkItems(link)
        } else if let link = target.linkURL {
            CtxHeader(text: target.linkText.isEmpty ? link : target.linkText)
            CtxRow(icon: "rectangle.badge.plus", title: "Open Link in New Tab") {
                store.ctxOpenLink(link, inBackground: false)
            }
            CtxRow(icon: "rectangle.on.rectangle", title: "Open in Background Tab") {
                store.ctxOpenLink(link, inBackground: true)
            }
            CtxRow(icon: "eye", title: "Open in Peek") {
                store.ctxPeekLink(link)
            }
            CtxRow(icon: "square.grid.2x2", title: "Open Link in Space", trailing: "chevron.right") {
                page = .spaces
            }
            CtxRow(icon: "link", title: "Copy Link Address") {
                store.ctxCopy(link, message: "Link copied")
            }
            CtxRow(icon: "square.and.arrow.up", title: "Share Link…") {
                store.ctxShare(link)
            }
        }

        if let image = target.imageURL {
            if target.linkURL != nil { CtxDivider() }
            CtxRow(icon: "photo", title: "Open Image in New Tab") {
                store.ctxOpenImage(image)
            }
            CtxRow(icon: "square.and.arrow.down", title: "Save Image…") {
                store.ctxSaveImage(image)
            }
            CtxRow(icon: "doc.on.doc", title: "Copy Image") {
                store.ctxCopyImage(image)
            }
            CtxRow(icon: "link", title: "Copy Image Address") {
                store.ctxCopy(image, message: "Image address copied")
            }
            CtxRow(icon: "magnifyingglass", title: "Search Image with Google") {
                store.ctxSearchImage(image)
            }
        }

        // Bare page (no link or image): a default page menu so a right-click
        // anywhere always shows something.
        if !target.hasContent {
            pageItems
        }

        // Inspect is available on every menu, mirroring Chrome.
        CtxDivider()
        CtxRow(icon: "chevron.left.forwardslash.chevron.right", title: "Inspect Element") {
            store.ctxInspect()
        }
    }

    /// Items for a non-web link (mailto:/tel:/…) — mirrors what Safari/Arc show:
    /// act via the OS default app, and copy the bare address.
    @ViewBuilder
    private func externalLinkItems(_ link: String) -> some View {
        CtxHeader(text: externalDisplay(link))
        switch BrowserURLPolicy.scheme(of: link) {
        case "mailto":
            CtxRow(icon: "envelope", title: "New Email") { store.ctxOpenExternal(link) }
            CtxRow(icon: "doc.on.doc", title: "Copy Email Address") {
                store.ctxCopy(externalAddress(link), message: "Email address copied")
            }
        case "tel", "facetime", "facetime-audio":
            CtxRow(icon: "phone", title: "Call") { store.ctxOpenExternal(link) }
            CtxRow(icon: "doc.on.doc", title: "Copy Phone Number") {
                store.ctxCopy(externalAddress(link), message: "Phone number copied")
            }
        default:
            CtxRow(icon: "arrow.up.forward.app", title: "Open in Default App") {
                store.ctxOpenExternal(link)
            }
            CtxRow(icon: "link", title: "Copy Address") {
                store.ctxCopy(link, message: "Address copied")
            }
        }
    }

    /// The bare address behind an external link: strips the scheme + any mailto
    /// query and percent-decodes ("mailto:a@b.com?subject=Hi" → "a@b.com").
    private func externalAddress(_ link: String) -> String {
        var s = link
        if let colon = s.firstIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        s = s.components(separatedBy: "?").first ?? s
        return s.removingPercentEncoding ?? s
    }

    private func externalDisplay(_ link: String) -> String {
        let addr = externalAddress(link)
        return addr.isEmpty ? link : addr
    }

    @ViewBuilder
    private var pageItems: some View {
        if !target.selection.isEmpty {
            CtxRow(icon: "doc.on.doc", title: "Copy") {
                store.ctxCopy(target.selection, message: "Copied")
            }
            CtxRow(icon: "magnifyingglass", title: "Search for “\(searchSnippet)”") {
                store.ctxSearchText(target.selection)
            }
            CtxRow(icon: "character.book.closed", title: "Look Up “\(searchSnippet)”") {
                store.ctxLookUp(target.selection)
            }
            CtxRow(icon: "speaker.wave.2", title: "Speak") {
                store.ctxSpeak(target.selection)
            }
            CtxRow(icon: "square.and.arrow.up", title: "Share…") {
                store.ctxShare(target.selection)
            }
            CtxDivider()
        }
        if store.selectedTab?.canGoBack == true {
            CtxRow(icon: "chevron.left", title: "Back") { store.ctxGoBack() }
        }
        if store.selectedTab?.canGoForward == true {
            CtxRow(icon: "chevron.right", title: "Forward") { store.ctxGoForward() }
        }
        CtxRow(icon: "arrow.clockwise", title: "Reload") { store.ctxReload() }
        CtxDivider()
        CtxRow(icon: "link", title: "Copy Page Link") {
            store.ctxCopy(store.selectedTab?.urlString ?? "", message: "Link copied")
        }
        if store.selectedTab?.urlString.hasPrefix("http") == true {
            CtxRow(icon: "square.and.arrow.up", title: "Share Page…") {
                store.ctxShare(store.selectedTab?.urlString ?? "")
            }
        }
        if store.selectedTab?.urlString.hasPrefix("http") == true {
            CtxRow(icon: "chevron.left.forwardslash.chevron.right",
                   title: "View Page Source") {
                store.ctxViewSource()
            }
        }
    }

    /// Selection text trimmed for the "Search for …" menu label.
    private var searchSnippet: String {
        let s = target.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 30 ? String(s.prefix(30)) + "…" : s
    }

    @ViewBuilder
    private var spaceItems: some View {
        CtxRow(icon: "chevron.left", title: "Back") { page = .main }
        CtxDivider()
        if let link = target.linkURL {
            ForEach(store.contexts) { context in
                CtxRow(icon: "circle.fill", title: context.name) {
                    store.ctxOpenLink(link, inContext: context.id)
                }
            }
        }
    }
}

private struct CtxHeader: View {
    let text: String
    @Environment(\.palette) private var p

    var body: some View {
        Text(text)
            .font(Typography.ui(Typography.small, weight: .medium))
            .foregroundStyle(p.mutedForeground.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CtxDivider: View {
    @Environment(\.palette) private var p
    var body: some View {
        Rectangle()
            .fill(p.border.color.opacity(0.5))
            .frame(height: 1)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
    }
}

private struct CtxRow: View {
    let icon: String
    let title: String
    var trailing: String? = nil
    let action: () -> Void

    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Icon(name: icon, size: 13)
                    .foregroundStyle(hovering ? p.primaryForeground.color : p.mutedForeground.color)
                    .frame(width: 16)
                Text(title)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(hovering ? p.primaryForeground.color : p.popoverForeground.color)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let trailing {
                    Icon(name: trailing, size: 10)
                        .foregroundStyle(hovering ? p.primaryForeground.color : p.mutedForeground.color)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? p.primary.color : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }
}
