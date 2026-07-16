import SwiftUI
import AppKit

/// The cluster shown at the trailing edge of the omnibox: pinned extensions as
/// their own icon buttons, followed by the puzzle-piece button that opens the
/// full extensions menu. Everything reflects Chrome's real extension state.
struct ExtensionToolbarItems: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var p
    @State private var menuVisible = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(extensions.pinnedExtensions) { ext in
                ExtensionActionButton(ext: ext)
            }

            Button {
                menuVisible.toggle()
            } label: {
                Icon(name: "puzzlepiece.extension", size: 12)
                    .foregroundStyle(p.mutedForeground.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Extensions")
            .popover(isPresented: $menuVisible, arrowEdge: .bottom) {
                ExtensionsMenu(store: store) { menuVisible = false }
            }
        }
        // Badge/title state is per-tab; keep the snapshot fresh as the user
        // switches tabs.
        .onChange(of: store.selectedTabID) { _, _ in extensions.refresh() }
    }
}

/// Box handing the underlying NSView to SwiftUI buttons so action popups can
/// anchor to the clicked button's true screen rect.
private final class AnchorBox {
    weak var view: NSView?

    var screenRect: NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// A pinned extension's icon button in the omnibox, with its live badge.
/// Clicking runs the real Chrome action (onClicked / popup / side panel).
private struct ExtensionActionButton: View {
    let ext: ChromeExtensionInfo
    @Environment(\.palette) private var p
    @State private var hover = false
    private let anchor = AnchorBox()

    var body: some View {
        Button {
            ExtensionStore.shared.runAction(ext, anchor: anchor.screenRect)
        } label: {
            ExtensionIconView(ext: ext, size: 16)
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) { badge }
                .background(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(hover ? p.foreground.color.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader(box: anchor))
        .onHover { hover = $0 }
        .animation(Motion.snappy, value: hover)
        .help(ext.actionTitle.isEmpty ? ext.name : ext.actionTitle)
    }

    @ViewBuilder private var badge: some View {
        if !ext.badgeText.isEmpty {
            Text(String(ext.badgeText.prefix(4)))
                .font(Typography.ui(7, weight: .bold))
                .foregroundStyle(ext.badgeTextColor.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
                .frame(minWidth: 11, minHeight: 10)
                .background(Capsule().fill(ext.badgeBackgroundColor.color))
                .offset(x: 5, y: -3)
        }
    }
}

private extension Array where Element == Int {
    var color: Color {
        let r = Double(indices.contains(0) ? self[0] : 217) / 255.0
        let g = Double(indices.contains(1) ? self[1] : 48) / 255.0
        let b = Double(indices.contains(2) ? self[2] : 37) / 255.0
        let a = Double(indices.contains(3) ? self[3] : 255) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// Reusable square icon for an extension: its real Chrome icon, or a
/// puzzle-piece placeholder. Dimmed when the extension is disabled.
struct ExtensionIconView: View {
    let ext: ChromeExtensionInfo
    var size: CGFloat = 28
    @Environment(\.palette) private var p

    var body: some View {
        Group {
            if let icon = ext.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(p.input.color.opacity(0.6))
                    .frame(width: size, height: size)
                    .overlay(
                        Icon(name: "puzzlepiece.extension", size: size * 0.6, weight: .regular)
                            .foregroundStyle(p.mutedForeground.color)
                    )
            }
        }
        .opacity(ext.enabled ? 1 : 0.4)
    }
}

/// The extensions/site control panel opened from the omnibox puzzle button.
/// Three sections mirroring Arc's site menu: an icon grid of installed
/// extensions (+ Add), Settings toggles (extension developer mode, automatic
/// PiP), and a "Secure" site footer whose ··· menu carries per-site/data and
/// boost/extension actions.
struct ExtensionsMenu: View {
    @ObservedObject var store: BrowserStore
    let dismiss: () -> Void

    @ObservedObject private var extensions = ExtensionStore.shared
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.palette) private var p

    @State private var devMode = false
    @State private var siteBlocked = false
    @State private var adsAllowed = false

    // The active page as a web URL (nil on chrome:// / start pages).
    private var siteURL: String? {
        guard let u = store.selectedTab?.urlString, u.hasPrefix("http") else { return nil }
        return u
    }
    private var siteHost: String? { siteURL.flatMap { SiteBrand.host(from: $0) } }
    private var isSecure: Bool { store.selectedTab?.urlString.hasPrefix("https://") ?? false }

    private let gridColumns = Array(
        repeating: GridItem(.fixed(46), spacing: 4, alignment: .center), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Extensions")
            extensionGrid

            Hairline().opacity(0.6)

            sectionHeader("Settings")
            settingsSection

            secureFooter
        }
        .frame(width: 300)
        .background(p.popover.color)
        .onAppear {
            extensions.refresh()
            devMode = MoriChromeExtensions.developerMode()
            if let s = siteURL { siteBlocked = extensions.areExtensionsBlocked(onSite: s) }
            if let h = siteHost { adsAllowed = AdBlockStore.shared.isAllowed(host: h) }
        }
    }

    // MARK: - Extensions grid

    @ViewBuilder private var extensionGrid: some View {
        if extensions.extensions.isEmpty {
            HStack {
                Text("No extensions installed.")
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.mutedForeground.color)
                Spacer()
                addButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 4) {
                    ForEach(extensions.extensions) { ext in
                        GridExtCell(
                            ext: ext,
                            onActivate: { anchor in dismiss(); extensions.runAction(ext, anchor: anchor) },
                            onTogglePin: { extensions.togglePinned(ext) },
                            dismiss: dismiss)
                    }
                    addButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 168)
        }
    }

    private var addButton: some View {
        Button { extensions.presentImportPanel(); dismiss() } label: {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(p.border.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 34, height: 34)
                .overlay(Icon(name: "plus", size: 13, weight: .medium)
                    .foregroundStyle(p.mutedForeground.color))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add an extension")
    }

    // MARK: - Settings

    @ViewBuilder private var settingsSection: some View {
        settingRow(icon: "chevron.left.forwardslash.chevron.right",
                   title: "Developer Mode",
                   value: devMode ? "On" : "Off",
                   on: devMode) {
            devMode.toggle()
            MoriChromeExtensions.setDeveloperMode(devMode)
        }
        settingRow(icon: "pip",
                   title: "Automatic Picture-in-Picture",
                   value: settings.autoPiP ? "Allowed" : "Off",
                   on: settings.autoPiP) {
            settings.autoPiP.toggle()
        }
    }

    private func settingRow(icon: String, title: String, value: String,
                            on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(on ? p.primary.color.opacity(0.14) : p.input.color.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .overlay(Icon(name: icon, size: 13, weight: .regular)
                        .foregroundStyle(on ? p.primary.color : p.mutedForeground.color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.foreground.color)
                        .lineLimit(1)
                    Text(value)
                        .font(Typography.ui(Typography.small))
                        .foregroundStyle(p.mutedForeground.color)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: .constant(on))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Secure footer + site menu

    private var secureFooter: some View {
        HStack(spacing: 8) {
            Icon(name: isSecure ? "lock.fill" : "lock.open.fill", size: 12, weight: .semibold)
                .foregroundStyle(isSecure ? p.statusSuccessFg.color : p.mutedForeground.color)
            Text(footerLabel)
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(p.foreground.color)
            Spacer()
            siteMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(p.input.color.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .padding(10)
    }

    private var footerLabel: String {
        if siteURL != nil { return isSecure ? "Secure" : "Not Secure" }
        return "Millie"
    }

    private var siteMenu: some View {
        Menu {
            Button("Clear Cache") {
                MoriPrivacy.clearCache()
                ToastCenter.shared.show("Cache cleared", icon: "trash", style: .success)
                dismiss()
            }
            Button("Clear Cookies") {
                MoriPrivacy.clearCookies()
                ToastCenter.shared.show("Cookies cleared", icon: "trash", style: .success)
                dismiss()
            }
            Divider()
            Button("Manage Boosts…") { store.presentBoostEditor(); dismiss() }
            Button("New Boost…") { store.presentBoostEditor(); dismiss() }
            Divider()
            Button("Manage Extensions…") { extensions.openManagePage(); dismiss() }
            Button("Add Extension…") { extensions.presentImportPanel(); dismiss() }
            if let s = siteURL {
                Divider()
                Toggle("Block extensions on this site", isOn: Binding(
                    get: { siteBlocked },
                    set: { v in
                        siteBlocked = v
                        extensions.setExtensionsBlocked(v, onSite: s)
                        store.reload()
                    }))
                if settings.blockAds, let host = siteHost {
                    Toggle("Don't block ads on this site", isOn: Binding(
                        get: { adsAllowed },
                        set: { v in
                            adsAllowed = v
                            AdBlockStore.shared.setAllowed(v, host: host)
                            store.reload()
                        }))
                }
                Button("All Site Settings…") { openSiteSettings(); dismiss() }
            }
        } label: {
            Icon(name: "ellipsis", size: 14, weight: .semibold)
                .foregroundStyle(p.mutedForeground.color)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Site & data")
    }

    private func openSiteSettings() {
        if let url = siteURL, let comps = URLComponents(string: url), let host = comps.host {
            let scheme = comps.scheme ?? "https"
            _ = store.newTab(url: "chrome://settings/content/siteDetails?site=\(scheme)://\(host)")
        } else {
            _ = store.newTab(url: "chrome://settings/content")
        }
    }

    // MARK: - Shared

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui(Typography.small, weight: .semibold))
            .foregroundStyle(p.mutedForeground.color)
            .textCase(.uppercase)
            .kerning(0.4)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

/// One extension in the panel's icon grid: click runs its action, the pin star
/// marks toolbar-pinned ones, and the context menu carries the full Chrome
/// per-extension controls (pin, options, details, enable/disable, remove).
private struct GridExtCell: View {
    let ext: ChromeExtensionInfo
    let onActivate: (NSRect) -> Void
    let onTogglePin: () -> Void
    let dismiss: () -> Void

    @ObservedObject private var extensions = ExtensionStore.shared
    @Environment(\.palette) private var p
    @State private var hover = false
    private let anchor = AnchorBox()

    var body: some View {
        Button { onActivate(anchor.screenRect) } label: {
            ExtensionIconView(ext: ext, size: 28)
                .overlay(alignment: .bottomTrailing) {
                    if ext.pinned {
                        Icon(name: "star.fill", size: 8)
                            .foregroundStyle(p.primary.color)
                            .padding(2)
                            .background(Circle().fill(p.popover.color))
                            .offset(x: 3, y: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !ext.badgeText.isEmpty {
                        Text(String(ext.badgeText.prefix(3)))
                            .font(Typography.ui(7, weight: .bold))
                            .foregroundStyle(ext.badgeTextColor.color)
                            .padding(.horizontal, 2)
                            .frame(minWidth: 10, minHeight: 9)
                            .background(Capsule().fill(ext.badgeBackgroundColor.color))
                            .offset(x: 4, y: -3)
                    }
                }
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(hover ? p.accent.color.opacity(0.5) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ext.enabled)
        .background(AnchorReader(box: anchor))
        .onHover { hover = $0 }
        .animation(Motion.snappy, value: hover)
        .help(ext.enabled ? ext.name : "\(ext.name) (disabled)")
        .contextMenu {
            Button(ext.pinned ? "Unpin from toolbar" : "Pin to toolbar", action: onTogglePin)
                .disabled(!ext.enabled)
            if ext.hasOptionsPage {
                Button("Options…") { extensions.openOptions(ext); dismiss() }
            }
            Button("Details") { extensions.openDetailsPage(ext); dismiss() }
            Divider()
            if ext.mayDisable {
                Button(ext.enabled ? "Disable" : "Enable") {
                    extensions.setEnabled(ext, !ext.enabled)
                }
                Button("Remove from Millie…") { dismiss(); extensions.remove(ext) }
            }
        }
    }
}
