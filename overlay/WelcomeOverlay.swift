import SwiftUI

/// First-run welcome tour. A paginated, full feature walkthrough shown once on a
/// new install (gated by `BrowserSettings.welcomeSeen`) and re-openable any time
/// from Settings. The last page carries a "Don't show this again" toggle — the
/// user's off switch. Presented as a full-window overlay above the web content,
/// like the launcher / settings.
struct WelcomeOverlay: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    @State private var page = 0
    @State private var dontShowAgain = true

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let detail: String
    }
    private struct Page: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
        let features: [Feature]
    }

    private let pages: [Page] = [
        Page(icon: "sparkles", title: "Welcome to Millie",
             subtitle: "A fast, private browser with a lot under the hood. Here's a quick tour of what it can do — you can reopen this any time from Settings.",
             features: [
                Feature(icon: "square.grid.2x2", name: "Spaces", detail: "Separate, isolated browsing contexts — each with its own tabs, cookies/logins, and color theme."),
                Feature(icon: "sidebar.left", name: "Sidebar & command bar", detail: "Tabs live in the sidebar; ⌘T opens the command bar to search or jump anywhere."),
                Feature(icon: "paintpalette", name: "Themes", detail: "Each Space gets its own gradient wash — set a mood per context."),
             ]),
        Page(icon: "rectangle.stack", title: "Tabs, your way",
             subtitle: "Organize and move through tabs fast.",
             features: [
                Feature(icon: "pin", name: "Pinned tabs & folders", detail: "Pin the sites you always keep open; group the rest into folders."),
                Feature(icon: "rectangle.split.2x1", name: "Split view", detail: "Drag one tab onto another (or ⌃⇧=) to see two sites side by side."),
                Feature(icon: "arrow.left.arrow.right", name: "Quick switching", detail: "⌃Tab cycles most-recently-used tabs; ⌘1–9 jumps straight to one."),
                Feature(icon: "moon.zzz", name: "Sleep & auto-archive", detail: "Background tabs sleep to save memory and archive after a while to stay tidy."),
             ]),
        Page(icon: "sidebar.right", title: "Web Panels & Peek",
             subtitle: "Keep a site handy without leaving the page you're on.",
             features: [
                Feature(icon: "dock.rectangle", name: "Web Panels", detail: "Dock any site to the right — chat, music, docs — kept loaded and logged in. Drag its inner edge to resize."),
                Feature(icon: "eye", name: "Peek a link", detail: "⌘⇧O (or hover pinned links) to preview a link in a quick overlay without opening a tab."),
                Feature(icon: "sidebar.leading", name: "Sidebar peek", detail: "Slide the sidebar out on hover when it's hidden, then get your space back."),
             ]),
        Page(icon: "wand.and.stars", title: "Ask Millie",
             subtitle: "A built-in AI assistant that understands the page you're on.",
             features: [
                Feature(icon: "bubble.left.and.text.bubble.right", name: "Chat about any page", detail: "Open the assistant (⌘K) to summarize, extract, or answer questions about the current site."),
                Feature(icon: "cursorarrow.rays", name: "It can act for you", detail: "Ask it to navigate, click, and fill things in — it drives the page like you would."),
                Feature(icon: "lock.shield", name: "You control sharing", detail: "Page content is only shared with the assistant when you allow it, in Settings."),
             ]),
        Page(icon: "book", title: "Read, tune & watch",
             subtitle: "Make any site nicer to use.",
             features: [
                Feature(icon: "doc.plaintext", name: "Reader mode", detail: "Strip the clutter for a clean, readable article view."),
                Feature(icon: "slider.horizontal.3", name: "Boosts", detail: "Apply your own CSS/JS to a site — hide noise or restyle it, and it sticks (⌘⇧B)."),
                Feature(icon: "play.rectangle", name: "Media & Picture-in-Picture", detail: "Control playback from the toolbar; video auto-pops into PiP when you switch tabs."),
                Feature(icon: "camera.viewfinder", name: "Capture", detail: "Screenshot a region or the full page in a couple of clicks."),
                Feature(icon: "magnifyingglass", name: "Find on page", detail: "⌘F to search within a page, ⌘G for the next match."),
             ]),
        Page(icon: "shield.lefthalf.filled", title: "Private & powerful",
             subtitle: "Fast and protective out of the box — and extensible when you want more.",
             features: [
                Feature(icon: "hand.raised", name: "Ad & tracker blocking", detail: "A built-in blocker speeds up pages and cuts clutter; allowlist any site you trust."),
                Feature(icon: "checkmark.shield", name: "Safe Browsing", detail: "Warns you before known phishing and malware sites."),
                Feature(icon: "key", name: "Passkeys", detail: "Sign in with passkeys — no passwords to type or leak."),
                Feature(icon: "square.and.arrow.down.on.square", name: "Import", detail: "Bring your bookmarks, history, and passwords from another browser."),
                Feature(icon: "puzzlepiece.extension", name: "Extensions", detail: "Install the Chrome extensions you rely on."),
                Feature(icon: "command", name: "Keyboard shortcuts", detail: "Press ⌘/ any time to see the full list."),
             ]),
    ]

    var body: some View {
        if store.welcomeVisible {
            ZStack {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { finish() }
                card
            }
            .transition(.opacity)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            heroHeader
            Rectangle().fill(p.border.color.opacity(0.4)).frame(height: 1)
            ScrollView { featureList.padding(.horizontal, 28).padding(.vertical, 22) }
                .frame(height: 300)
            Rectangle().fill(p.border.color.opacity(0.4)).frame(height: 1)
            footer
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
            .fill(p.background.color))
        .overlay(RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
            .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 40, y: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var current: Page { pages[min(page, pages.count - 1)] }

    private var heroHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(p.accent.color.opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: current.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(p.accent.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(current.title)
                    .font(Typography.ui(22, weight: .semibold))
                    .foregroundStyle(p.foreground.color)
                Text(current.subtitle)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.mutedForeground.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26).padding(.bottom, 20)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(current.features) { f in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: f.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(p.accent.color)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(p.input.color.opacity(0.5)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                            .font(Typography.ui(Typography.base, weight: .semibold))
                            .foregroundStyle(p.foreground.color)
                        Text(f.detail)
                            .font(Typography.ui(Typography.label))
                            .foregroundStyle(p.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if page == pages.count - 1 {
                Toggle(isOn: $dontShowAgain) {
                    Text("Don't show this again")
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                }
                .toggleStyle(.checkbox)
            } else {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
            }

            Spacer()

            // Page dots
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? p.accent.color : p.border.color.opacity(0.8))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if page > 0 {
                Button("Back") { withAnimation(.easeInOut(duration: 0.18)) { page -= 1 } }
                    .buttonStyle(.plain)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
            }
            Button(page == pages.count - 1 ? "Get started" : "Next") {
                if page == pages.count - 1 { finish() }
                else { withAnimation(.easeInOut(duration: 0.18)) { page += 1 } }
            }
            .buttonStyle(.plain)
            .font(Typography.ui(Typography.base, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .fill(p.accent.color))
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    private func finish() {
        if dontShowAgain { settings.welcomeSeen = true }
        withAnimation(.easeInOut(duration: 0.2)) { store.welcomeVisible = false }
        page = 0
    }
}
