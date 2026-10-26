import SwiftUI

/// A three-step first-run setup, reopenable from Settings.
struct WelcomeOverlay: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    @State private var page = 0

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
        Page(icon: "square.and.arrow.down", title: "Make yourself at home",
             subtitle: "Bring your bookmarks and history with you, or start fresh.",
             features: [
                Feature(icon: "square.and.arrow.down", name: "Import from your browser", detail: "Choose the browser and profile to import. You decide what to bring."),
                Feature(icon: "hand.raised", name: "Private by default", detail: "Online search suggestions are off. Private Spaces don't save history or archive tabs."),
             ]),
        Page(icon: "rectangle.stack", title: "A Space for each part of your day",
             subtitle: "Keep your tabs organized without mixing your identities.",
             features: [
                Feature(icon: "rectangle.stack", name: "Separate your tabs", detail: "Create Spaces for work, home, or a project. Switch with Control–1 through 9."),
                Feature(icon: "person.crop.circle", name: "Choose a profile", detail: "Spaces can share a profile. Assign different profiles when you want separate logins and histories."),
             ]),
        Page(icon: "magnifyingglass", title: "One shortcut to go anywhere",
             subtitle: "Press ⌘T to search, open a page, or switch tabs.",
             features: [
                Feature(icon: "magnifyingglass", name: "Search and switch", detail: "Type a site, a question, or a tab's name. Press Return to open the result."),
                Feature(icon: "command", name: "Learn as you go", detail: "Press ⌘/ for shortcuts. Settings has search for everything else, including split view, web panels, and the assistant."),
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    featureList
                    Button(page == 0 ? "Import from another browser…" : page == 1 ? "Create a Space…" : "Try the command bar") {
                        let step = page
                        finish()
                        if step == 0 { store.presentImportPanel() }
                        else if step == 1 { store.contextCreationVisible = true }
                        else { store.presentLauncher() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
            }
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
            Button("Skip setup") { finish() }
                .buttonStyle(.plain)
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)

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
        settings.welcomeSeen = true
        withAnimation(.easeInOut(duration: 0.2)) { store.welcomeVisible = false }
        page = 0
    }
}
