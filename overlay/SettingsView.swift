import SwiftUI

/// The preferences page. Rendered full-bleed inside the browser card (not a
/// modal sheet). Styled to the Millie design system: quiet labels, token colors,
/// rounded-xl surfaces, segmented appearance control. The scrolling content is
/// centered and width-constrained so it stays readable on a wide window.
struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var settings = BrowserSettings.shared
    @ObservedObject private var extensions = ExtensionStore.shared
    @ObservedObject private var sync = MillieSync.shared
    @Environment(\.palette) private var p

    @State private var syncEmail = ""
    @State private var syncCode = ""

    // Ask Milly BYO-key drafts, reloaded when the selected provider changes.
    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""

    /// Comfortable reading column for the settings content.
    private let contentWidth: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    generalSection
                    searchSection
                    privacySection
                    aiSection
                    appearanceSection
                    tabsSection
                    profilesSection
                    syncSection
                    RoutingSection(store: store)
                    mediaSection
                    extensionsSection
                    aboutSection
                }
                .frame(maxWidth: contentWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.background.color)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                store.settingsVisible = false
            } label: {
                HStack(spacing: 5) {
                    Icon(name: "chevron.left", size: 13, weight: .semibold)
                    Text("Back")
                        .font(Typography.ui(Typography.base, weight: .medium))
                }
                .foregroundStyle(p.foreground.color)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(p.input.color.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Back to browsing")
            .accessibilityLabel("Back to browsing")

            Text("Settings")
                .font(Typography.ui(Typography.title, weight: .semibold))
                .foregroundStyle(p.foreground.color)
            Spacer()
            Button {
                store.settingsVisible = false
            } label: {
                Text("Done")
                    .font(Typography.ui(Typography.base, weight: .medium))
                    .foregroundStyle(p.primaryForeground.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .fill(p.primary.color)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    // MARK: Sections

    /// Marketing version from the app bundle (set by release.sh per release),
    /// so the card always reflects the running build — not a hardcoded string.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    /// Chromium milestone, read from the embedded Chromium Framework bundle.
    private var chromiumVersion: String {
        let fw = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Chromium Framework.framework")
        return (Bundle(url: fw)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
    private var versionLine: String {
        chromiumVersion.isEmpty
            ? "Version \(appVersion)"
            : "Version \(appVersion) · Chromium \(chromiumVersion)"
    }

    private var aboutSection: some View {
        Section(title: "About") {
            HStack(alignment: .center, spacing: 14) {
                Icon(name: "glyph-millie", size: 40)
                    .foregroundStyle(p.primary.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Millie")
                        .font(Typography.ui(Typography.title, weight: .semibold))
                        .foregroundStyle(p.foreground.color)
                    Text("A native macOS browser built on Chromium.")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.mutedForeground.color)
                    Text(versionLine)
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                }
                Spacer(minLength: 0)
                Button("Check for Updates…") {
                    MillieUpdater.shared.checkForUpdates()
                }
                .buttonStyle(.plain)
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(p.primary.color)
            }
        }
    }

    private var generalSection: some View {
        Section(title: "General") {
            Field(label: "Homepage") {
                SettingTextField(text: $settings.homepageURL, placeholder: "https://…")
            }
            Field(label: "New tab opens") {
                EnumMenu(selection: $settings.newTabBehavior,
                         options: NewTabBehavior.allCases) { $0.label }
            }
        }
    }

    private var searchSection: some View {
        Section(title: "Search") {
            Field(label: "Search engine") {
                EnumMenu(selection: $settings.searchEngine,
                         options: SearchEngine.allCases) { $0.label }
            }
            if settings.searchEngine == .custom {
                Field(label: "Custom URL") {
                    SettingTextField(text: $settings.customSearchTemplate,
                                     placeholder: "https://example.com/?q={query}")
                }
                Text("Use {query} where the search terms should go.")
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
            }
        }
    }

    private var privacySection: some View {
        Section(title: "Privacy") {
            ToggleRow(isOn: $settings.blockAds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block ads")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.foreground.color)
                    Text("Use Millie's bundled Block List Project ads list.")
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                }
            }
        }
    }

    private var aiSection: some View {
        Section(title: "AI") {
            ToggleRow(isOn: $settings.aiIntegrationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI integration")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.foreground.color)
                    Text("Allow Millie to use the local Codex assistant and browser automation tools.")
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Hairline().opacity(0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ask Milly provider")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Text("Use the built-in Codex, or bring your own key for Claude, GPT or Gemini.")
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Field(label: "Provider") {
                EnumMenu(selection: $settings.assistantProvider,
                         options: AIProvider.allCases) { $0.label }
            }

            if settings.assistantProvider.needsKey {
                Field(label: "API key") {
                    SettingSecureField(text: $apiKeyDraft,
                                       placeholder: settings.assistantProvider.keyPlaceholder)
                        .onChange(of: apiKeyDraft) { _, v in
                            MillyAIClient.shared.setKey(v, for: settings.assistantProvider)
                        }
                }
                Field(label: "Model") {
                    SettingTextField(text: $modelDraft,
                                     placeholder: settings.assistantProvider.defaultModel)
                        .onChange(of: modelDraft) { _, v in
                            settings.setModel(v, for: settings.assistantProvider)
                        }
                }
                Text(MillyAIClient.shared.hasKey(for: settings.assistantProvider)
                     ? "Key stored in your macOS Keychain."
                     : "Enter a key to enable \(settings.assistantProvider.shortLabel).")
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
            }

            if settings.assistantProvider.needsKey {
                Hairline().opacity(0.5)

                ToggleRow(isOn: $settings.sharesPageWithAI) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share current page with AI")
                            .font(Typography.ui(Typography.base))
                            .foregroundStyle(p.foreground.color)
                        Text("Send the open page's text to \(settings.assistantProvider.shortLabel) as context for your questions. Private Spaces, internal pages and local files are never shared.")
                            .font(Typography.ui(Typography.label))
                            .foregroundStyle(p.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { loadAssistantDrafts() }
        .onChange(of: settings.assistantProvider) { _, _ in loadAssistantDrafts() }
    }

    private func loadAssistantDrafts() {
        let provider = settings.assistantProvider
        apiKeyDraft = MillyAIClient.shared.key(for: provider)
        modelDraft = settings.model(for: provider)
    }

    private var appearanceSection: some View {
        Section(title: "Appearance") {
            Field(label: "Theme") {
                SegmentedTheme(selection: $settings.theme)
            }
            Field(label: "Sidebar side") {
                EnumMenu(selection: $settings.sidebarPosition,
                         options: SidebarPosition.allCases) { $0.label }
            }
            ToggleRow(isOn: $settings.showSidebarOnLaunch) {
                Text("Show tab sidebar on launch")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
            }

            Hairline().opacity(0.5)

            VStack(alignment: .leading, spacing: 4) {
                Text("Color theme")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Text("Pick an anime-inspired theme to wash the chrome and accent.")
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
            }
            ThemeList()

            VStack(alignment: .leading, spacing: 8) {
                Text("Solid color")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Text("Or wash the chrome in a single flat color.")
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
                SolidThemeSwatches()
                    .padding(.top, 2)
            }
        }
    }

    private var tabsSection: some View {
        Section(title: "Tabs") {
            Field(label: "Sleep idle tabs") {
                IntMenu(value: $settings.autoSleepMinutes, options: Self.sleepOptions)
            }
            Field(label: "Archive idle tabs") {
                IntMenu(value: $settings.autoArchiveHours, options: Self.archiveOptions)
            }
            Field(label: "Ctrl+Tab cycles") {
                EnumMenu(selection: $settings.tabCycleOrder,
                         options: TabCycleOrder.allCases) { $0.label }
            }
            Text("\"Recently used\" makes Ctrl+Tab walk tabs in the order you last "
                 + "visited them (Arc / Dia style); \"Sidebar order\" follows their "
                 + "position in the sidebar.")
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sleeping frees a background tab's memory; it reloads when you return. "
                 + "Archiving closes stale tabs to the restorable Archive in your Library.")
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)
            Field(label: "Keyboard shortcuts") {
                Button("View all (⌘/)") {
                    store.settingsVisible = false
                    store.shortcutsHelpVisible = true
                }
                .buttonStyle(.plain)
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(p.primary.color)
            }
        }
    }

    private static let sleepOptions: [(Int, String)] = [
        (0, "Never"), (15, "15 minutes"), (30, "30 minutes"),
        (60, "1 hour"), (180, "3 hours"), (360, "6 hours")
    ]
    private static let archiveOptions: [(Int, String)] = [
        (0, "Never"), (12, "12 hours"), (24, "1 day"),
        (72, "3 days"), (168, "1 week"), (720, "30 days")
    ]

    private var profilesSection: some View {
        Section(title: "Profiles") {
            Text("Profiles keep cookies, logins, history, and extensions separate. "
                 + "Assign one to a Space when you create or edit it; many Spaces "
                 + "can share a Profile.")
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.profiles) { profile in
                HStack(spacing: 10) {
                    Icon(name: profile.symbol, size: 15)
                        .foregroundStyle(p.foreground.color)
                    TextField("Profile name", text: Binding(
                        get: { profile.name },
                        set: { store.renameProfile(profile.id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.foreground.color)
                        .disabled(profile.isDefault)
                    Spacer(minLength: 8)
                    let count = store.contexts.filter {
                        ($0.profileID ?? BrowserProfile.defaultID) == profile.id
                    }.count
                    Text(count == 1 ? "1 Space" : "\(count) Spaces")
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                    Button { store.moveProfile(profile.id, by: -1) } label: {
                        Icon(name: "chevron.up", size: 11)
                            .foregroundStyle(p.mutedForeground.color)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Move up")
                    Button { store.moveProfile(profile.id, by: 1) } label: {
                        Icon(name: "chevron.down", size: 11)
                            .foregroundStyle(p.mutedForeground.color)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Move down")
                    if !profile.isDefault {
                        Button { store.deleteProfile(profile.id) } label: {
                            Icon(name: "trash", size: 13)
                                .foregroundStyle(p.mutedForeground.color)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete Profile (its Spaces fall back to Default)")
                    }
                }
                .frame(height: 30)
            }
            Button {
                store.addProfile(name: "Profile \(store.profiles.count)")
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "plus", size: 12)
                    Text("Add Profile")
                        .font(Typography.ui(Typography.base, weight: .medium))
                }
                .foregroundStyle(p.primary.color)
            }
            .buttonStyle(.plain)
        }
    }

    private var syncSection: some View {
        Section(title: "Sync") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync with Milly")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Text("Share tabs, Spaces, bookmarks and history with the Milly iOS app.")
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.mutedForeground.color)
            }

            if sync.isSignedIn {
                HStack(spacing: 8) {
                    Icon(name: "glyph-millie", size: 14).foregroundStyle(p.primary.color)
                    Text("Signed in as \(sync.email ?? "account")")
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.foreground.color)
                    Spacer(minLength: 0)
                }
                Button { sync.signOut() } label: {
                    Text("Sign out")
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.destructive.color)
                }
                .buttonStyle(.plain)
            } else if sync.codeSent {
                SettingTextField(text: $syncCode, placeholder: "6-digit code")
                Button {
                    Task { await sync.verify(code: syncCode); syncCode = "" }
                } label: {
                    Text("Verify").font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.primary.color)
                }
                .buttonStyle(.plain)
            } else {
                SettingTextField(text: $syncEmail, placeholder: "you@email.com")
                Button {
                    Task { await sync.sendCode(email: syncEmail) }
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: "arrow.clockwise", size: 12)
                        Text("Send sign-in code").font(Typography.ui(Typography.base, weight: .medium))
                    }
                    .foregroundStyle(p.primary.color)
                }
                .buttonStyle(.plain)
            }

            if let msg = sync.statusMessage {
                Text(msg).font(Typography.ui(Typography.label)).foregroundStyle(p.mutedForeground.color)
            }
        }
    }

    private var mediaSection: some View {
        Section(title: "Media") {
            ToggleRow(isOn: $settings.autoPiP) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic Picture in Picture")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.foreground.color)
                    Text("Pop a playing video out when you switch tabs.")
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                }
            }
        }
    }

    private var extensionsSection: some View {
        Section(title: "Extensions") {
            if let error = extensions.lastError {
                Text(error)
                    .font(Typography.ui(Typography.label))
                    .foregroundStyle(p.destructive.color)
            }

            if !extensions.extensions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(extensions.extensions) { ext in
                        ExtensionRow(ext: ext, store: extensions)
                        if ext.id != extensions.extensions.last?.id {
                            Hairline().opacity(0.5)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    extensions.presentImportPanel()
                } label: {
                    HStack(spacing: 5) {
                        Icon(name: "plus", size: 12, weight: .semibold)
                        Text("Load Unpacked…")
                            .font(Typography.ui(Typography.base, weight: .medium))
                    }
                    .foregroundStyle(p.foreground.color)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(p.input.color.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    extensions.openManagePage()
                } label: {
                    HStack(spacing: 5) {
                        Icon(name: "puzzlepiece.extension", size: 12, weight: .regular)
                        Text("Manage…")
                            .font(Typography.ui(Typography.base, weight: .medium))
                    }
                    .foregroundStyle(p.foreground.color)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(p.input.color.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Text("Extensions are installed and managed by Chrome's native extension service.")
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Extension row

private struct ExtensionRow: View {
    let ext: ChromeExtensionInfo
    @ObservedObject var store: ExtensionStore
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 11) {
            ExtensionIconView(ext: ext, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.name)
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.foreground.color)
                        .lineLimit(1)
                    if !ext.version.isEmpty {
                        Text("v\(ext.version)")
                            .font(Typography.ui(Typography.small))
                            .foregroundStyle(p.mutedForeground.color)
                    }
                    if ext.installType == "development" {
                        Text("Unpacked")
                            .font(Typography.ui(Typography.small))
                            .foregroundStyle(p.mutedForeground.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(p.input.color.opacity(0.6)))
                    }
                }
                if !ext.detail.isEmpty {
                    Text(ext.detail)
                        .font(Typography.ui(Typography.label))
                        .foregroundStyle(p.mutedForeground.color)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)

            if ext.hasOptionsPage {
                Button {
                    store.openOptions(ext)
                } label: {
                    Icon(name: "slider.horizontal.3", size: 14, weight: .regular)
                        .foregroundStyle(p.mutedForeground.color)
                }
                .buttonStyle(.plain)
                .help("Extension options")
            }

            Toggle("", isOn: Binding(
                get: { ext.enabled },
                set: { store.setEnabled(ext, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(p.primary.color)
            .disabled(!ext.mayDisable)

            Button {
                store.remove(ext)
            } label: {
                Icon(name: "trash", size: 14, weight: .regular)
                    .foregroundStyle(p.mutedForeground.color)
            }
            .buttonStyle(.plain)
            .disabled(!ext.mayDisable)
            .help("Remove extension")
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(Typography.ui(Typography.small, weight: .medium))
                .foregroundStyle(p.mutedForeground.color)
                .tracking(0.4)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                    .fill(p.card.color.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                    .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
            )
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(Typography.ui(Typography.base))
                .foregroundStyle(p.foreground.color)
                .frame(width: 120, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct ToggleRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(p.primary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingTextField: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.palette) private var p

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typography.ui(Typography.base))
            .foregroundStyle(p.foreground.color)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(p.input.color.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
            )
    }
}

/// Obscured single-line field, styled to match `SettingTextField` (API keys).
private struct SettingSecureField: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.palette) private var p

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typography.ui(Typography.base))
            .foregroundStyle(p.foreground.color)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(p.input.color.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
            )
    }
}

/// A dropdown over preset integer values (used for sleep/archive intervals).
private struct IntMenu: View {
    @Binding var value: Int
    let options: [(Int, String)]
    @Environment(\.palette) private var p

    private var label: String {
        options.first { $0.0 == value }?.1 ?? "\(value)"
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { value = option.0 }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Icon(name: "chevron.up.chevron.down", size: 12)
                    .foregroundStyle(p.mutedForeground.color)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(p.input.color.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Air Traffic Control: routing rules that send hosts to a chosen space.
private struct RoutingSection: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var routes = RouteStore.shared
    @Environment(\.palette) private var p
    @State private var newPattern = ""
    @State private var newContextID: BrowserContext.ID?

    var body: some View {
        Section(title: "Air Traffic Control") {
            Text("Open matching sites in a chosen space automatically.")
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)

            if !routes.rules.isEmpty {
                VStack(spacing: 0) {
                    ForEach(routes.rules) { rule in
                        ruleRow(rule)
                        if rule.id != routes.rules.last?.id {
                            Hairline().opacity(0.5)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                SettingTextField(text: $newPattern, placeholder: "figma.com")
                Menu {
                    ForEach(store.contexts) { context in
                        Button(context.name) { newContextID = context.id }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selectedContextName)
                            .font(Typography.ui(Typography.base))
                            .foregroundStyle(p.foreground.color)
                            .lineLimit(1)
                        Icon(name: "chevron.up.chevron.down", size: 11)
                            .foregroundStyle(p.mutedForeground.color)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(p.input.color.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button("Add") { addRule() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var resolvedContextID: BrowserContext.ID? {
        newContextID ?? store.contexts.first?.id
    }

    private var selectedContextName: String {
        store.contexts.first { $0.id == resolvedContextID }?.name ?? "Space"
    }

    private func ruleRow(_ rule: RoutingRule) -> some View {
        HStack(spacing: 10) {
            Icon(name: "arrow.triangle.branch", size: 13)
                .foregroundStyle(p.mutedForeground.color)
            Text(rule.pattern)
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(p.foreground.color)
            Icon(name: "arrow.right", size: 11)
                .foregroundStyle(p.mutedForeground.color)
            Text(store.contexts.first { $0.id == rule.contextID }?.name ?? "—")
                .font(Typography.ui(Typography.base))
                .foregroundStyle(p.mutedForeground.color)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { routes.setEnabled($0, for: rule) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(p.primary.color)
            Button { routes.remove(rule) } label: {
                Icon(name: "trash", size: 13)
                    .foregroundStyle(p.mutedForeground.color)
            }
            .buttonStyle(.plain)
            .help("Remove rule")
        }
        .padding(.vertical, 8)
    }

    private func addRule() {
        guard let contextID = resolvedContextID else { return }
        if routes.add(pattern: newPattern, contextID: contextID) {
            newPattern = ""
        }
    }
}

/// A dropdown driven by a `CaseIterable` enum, styled like a Millie select.
private struct EnumMenu<T: Hashable & Identifiable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    @Environment(\.palette) private var p

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(label(option)) { selection = option }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(selection))
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Icon(name: "chevron.up.chevron.down", size: 12)
                    .foregroundStyle(p.mutedForeground.color)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(p.input.color.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Three-up segmented control for the theme preference.
private struct SegmentedTheme: View {
    @Binding var selection: ThemePreference
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ThemePreference.allCases) { option in
                let active = option == selection
                Button {
                    withAnimation(Motion.state) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        Icon(name: option.symbol, size: 13)
                        Text(option.label)
                            .font(Typography.ui(Typography.label))
                    }
                    .foregroundStyle(active ? p.foreground.color : p.mutedForeground.color)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(active ? p.background.color : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(active ? p.border.color.opacity(0.7) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(p.input.color.opacity(0.5))
        )
    }
}
