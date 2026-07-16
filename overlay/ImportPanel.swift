import SwiftUI

/// Arc-style "Import from your old browser" overlay: a centered card that lists
/// the Chromium-family browsers found on disk, lets the user pick one (and its
/// profile) plus which data to bring over, runs the import, and shows a summary.
struct ImportPanelOverlay: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            if store.importPanelVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { store.dismissImportPanel() }
                    .transition(.opacity)

                ImportCard(store: store)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(Motion.reveal, value: store.importPanelVisible)
    }
}

private struct ImportCard: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var importer = BrowserImporter.shared
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().opacity(0.5)
            content
        }
        .frame(width: 560, height: 460)
        .background(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .fill(p.popover.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .strokeBorder(p.border.color.opacity(Stroke.border), lineWidth: 1))
        .elevation(.overlay, scheme)
        .onAppear { importer.detect() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Icon(name: "square.and.arrow.down.on.square", size: 18)
                .foregroundStyle(p.primary.color)
            Text("Import from your old browser")
                .font(Typography.ui(Typography.title, weight: .semibold))
                .foregroundStyle(p.popoverForeground.color)
            Spacer()
            Button { store.dismissImportPanel() } label: {
                Icon(name: "xmark", size: 12, weight: .semibold)
                    .foregroundStyle(p.mutedForeground.color)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let result = importer.result {
            summary(result)
        } else if importer.browsers.isEmpty {
            emptyState
        } else {
            selection
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Icon(name: "magnifyingglass", size: 26)
                .foregroundStyle(p.mutedForeground.color)
            Text("No other browsers found")
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(p.foreground.color)
            Text("Millie looks for Chrome, Brave, Edge, Arc, Vivaldi, and Chromium.")
                .font(Typography.ui(Typography.small))
                .foregroundStyle(p.mutedForeground.color)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var selection: some View {
        HStack(alignment: .top, spacing: 0) {
            browserList
            Divider().overlay(p.border.color.opacity(0.5))
            detail
        }
    }

    // Left column: choose a browser.
    private var browserList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(importer.browsers) { browser in
                    Button { importer.selectBrowser(browser.id) } label: {
                        HStack(spacing: 10) {
                            Icon(name: iconName(browser.id), size: 18)
                                .foregroundStyle(p.foreground.color)
                            Text(browser.name)
                                .font(Typography.ui(Typography.base, weight: .medium))
                                .foregroundStyle(p.foreground.color)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if browser.id == importer.selectedBrowserID {
                                Icon(name: "checkmark.circle.fill", size: 14)
                                    .foregroundStyle(p.primary.color)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .fill(browser.id == importer.selectedBrowserID
                                      ? p.accent.color.opacity(0.5) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 210)
    }

    // Right column: profile picker + data types + action.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let browser = importer.selectedBrowser,
                       browser.profiles.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("Profile")
                            Menu {
                                ForEach(browser.profiles) { prof in
                                    Button(prof.name) {
                                        importer.selectedProfileDir = prof.dir
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(currentProfileName(browser))
                                        .font(Typography.ui(Typography.base))
                                        .foregroundStyle(p.foreground.color)
                                    Spacer()
                                    Icon(name: "chevron.up.chevron.down", size: 10)
                                        .foregroundStyle(p.mutedForeground.color)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: Radius.md)
                                    .fill(p.input.color.opacity(0.5)))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("What to import")
                        ForEach(ImportDataType.allCases) { type in
                            typeRow(type)
                        }
                    }

                    if importer.selectedTypes.contains(where: { $0.isEncrypted }) {
                        Text("Passwords, cookies, and payment methods are decrypted with the source browser's key — macOS may ask you to allow access to its Safe Storage once.")
                            .font(Typography.ui(Typography.label))
                            .foregroundStyle(p.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            Hairline().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity)
    }

    private func typeRow(_ type: ImportDataType) -> some View {
        let on = importer.selectedTypes.contains(type)
        return Button {
            if on { importer.selectedTypes.remove(type) }
            else { importer.selectedTypes.insert(type) }
        } label: {
            HStack(spacing: 10) {
                Icon(name: on ? "checkmark.square.fill" : "square", size: 15)
                    .foregroundStyle(on ? p.primary.color : p.mutedForeground.color)
                Icon(name: type.icon, size: 13)
                    .foregroundStyle(p.mutedForeground.color)
                Text(type.label)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(importer.running ? "Importing…" : " ")
                .font(Typography.ui(Typography.small))
                .foregroundStyle(p.mutedForeground.color)
            Spacer()
            Button("Maybe Later") { store.dismissImportPanel() }
                .buttonStyle(.plain)
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(p.foreground.color)
                .padding(.horizontal, 14).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Radius.button)
                    .fill(p.input.color.opacity(0.5)))

            Button("Import") {
                importer.runImport(targetProfileKey: targetProfileKey)
            }
            .buttonStyle(.plain)
            .font(Typography.ui(Typography.base, weight: .medium))
            .foregroundStyle(p.primaryForeground.color)
            .padding(.horizontal, 16).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.button)
                .fill(importer.canImport ? p.primary.color : p.muted.color))
            .disabled(!importer.canImport)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: Summary

    private func summary(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Icon(name: "checkmark.circle.fill", size: 18)
                            .foregroundStyle(p.statusSuccessFg.color)
                        Text("Imported \(result.total) item\(result.total == 1 ? "" : "s")")
                            .font(Typography.ui(Typography.title, weight: .semibold))
                            .foregroundStyle(p.foreground.color)
                    }
                    summaryRow("Bookmarks", result.bookmarks)
                    summaryRow("History", result.history)
                    summaryRow("Passwords", result.passwords)
                    summaryRow("Cookies", result.cookies)
                    summaryRow("Payment methods", result.cards)

                    if !result.errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.errors, id: \.self) { err in
                                HStack(alignment: .top, spacing: 6) {
                                    Icon(name: "exclamationmark.triangle", size: 11)
                                        .foregroundStyle(p.statusWarningFg.color)
                                    Text(err)
                                        .font(Typography.ui(Typography.label))
                                        .foregroundStyle(p.mutedForeground.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            Hairline().opacity(0.5)
            HStack {
                Spacer()
                Button("Done") { store.dismissImportPanel() }
                    .buttonStyle(.plain)
                    .font(Typography.ui(Typography.base, weight: .medium))
                    .foregroundStyle(p.primaryForeground.color)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: Radius.button)
                        .fill(p.primary.color))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
        }
    }

    private func summaryRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
                .font(Typography.ui(Typography.base))
                .foregroundStyle(p.mutedForeground.color)
            Spacer()
            Text("\(count)")
                .font(Typography.ui(Typography.base, weight: .medium))
                .foregroundStyle(count > 0 ? p.foreground.color : p.mutedForeground.color)
        }
    }

    // MARK: Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui(Typography.small, weight: .semibold))
            .foregroundStyle(p.mutedForeground.color)
            .textCase(.uppercase)
            .kerning(0.4)
    }

    private func currentProfileName(_ browser: DetectedBrowser) -> String {
        browser.profiles.first { $0.dir == importer.selectedProfileDir }?.name
            ?? browser.profiles.first?.name ?? "Default"
    }

    /// Target for the encrypted stores: the active Space's profile, or the
    /// default profile when the active Space is private (can't import into OTR).
    private var targetProfileKey: String {
        let key = store.engineKey(for: store.activeContext)
        return key == "incognito" ? "default" : key
    }

    private func iconName(_ browserId: String) -> String {
        switch browserId {
        case "brave":    return "shield"
        case "edge":     return "globe.americas"
        case "arc":      return "circle.hexagongrid.fill"
        case "vivaldi":  return "globe.europe.africa"
        default:         return "globe"  // chrome, chromium, unknown
        }
    }
}
