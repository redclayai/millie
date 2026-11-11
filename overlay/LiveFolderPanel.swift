import SwiftUI

/// "New live folder" overlay (Arc parity): a centered card to name a folder and
/// point it at a source (RSS / Atom feed, or a GitHub repo's PRs / issues). On
/// create, `BrowserStore.addLiveFolder` makes the folder and kicks off a fetch.
struct LiveFolderPanelOverlay: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            if store.liveFolderPanelVisible {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { store.dismissLiveFolderPanel() }
                    .transition(.opacity)

                LiveFolderCard(store: store)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(Motion.reveal, value: store.liveFolderPanelVisible)
    }
}

private struct LiveFolderCard: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme

    @State private var name = ""
    @State private var kind: LiveFolderSource.Kind = .rss
    @State private var target = ""
    @FocusState private var targetFocused: Bool

    private var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canAdd: Bool { !trimmedTarget.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().opacity(0.5)
            content
        }
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .fill(p.popover.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popover, style: .continuous)
                .strokeBorder(p.border.color.opacity(Stroke.border), lineWidth: 1))
        .elevation(.overlay, scheme)
        .onAppear { targetFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Icon(name: "dot.radiowaves.up.forward", size: 18)
                .foregroundStyle(p.primary.color)
            Text("New live folder")
                .font(Typography.ui(Typography.title, weight: .semibold))
                .foregroundStyle(p.popoverForeground.color)
            Spacer()
            Button { store.dismissLiveFolderPanel() } label: {
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A live folder keeps its links in sync with an outside source — an RSS feed, or a GitHub repo's open pull requests or issues.")
                .font(Typography.ui(Typography.label))
                .foregroundStyle(p.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)

            field("Source") {
                Menu {
                    ForEach(LiveFolderSource.Kind.allCases) { k in
                        Button { kind = k } label: {
                            Label(k.label, systemImage: k.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: kind.symbol, size: 13)
                        Text(kind.label).font(Typography.ui(Typography.base))
                        Icon(name: "chevron.up.chevron.down", size: 10)
                            .foregroundStyle(p.mutedForeground.color)
                    }
                    .foregroundStyle(p.foreground.color)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            field(kind == .rss ? "Feed URL" : "Repository") {
                textField(kind.placeholder, text: $target)
                    .focused($targetFocused)
                    .onSubmit(add)
            }

            field("Name") {
                textField("Optional — defaults to the source", text: $name)
                    .onSubmit(add)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.dismissLiveFolderPanel() }
                    .buttonStyle(.plain)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.mutedForeground.color)
                Button(action: add) {
                    Text("Add folder")
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Radius.md)
                            .fill(p.primary.color.opacity(canAdd ? 1 : 0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
    }

    private func add() {
        guard canAdd else { return }
        let source = LiveFolderSource(kind: kind, target: trimmedTarget)
        let folderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = folderName.isEmpty ? defaultName(for: source) : folderName
        store.addLiveFolder(name: finalName, source: source)
        store.dismissLiveFolderPanel()
    }

    private func defaultName(for source: LiveFolderSource) -> String {
        switch source.kind {
        case .rss:
            return URLComponents(string: trimmedTarget)?.host?
                .replacingOccurrences(of: "www.", with: "") ?? "Feed"
        case .githubPRs:
            return "\(repoName(trimmedTarget)) · PRs"
        case .githubIssues:
            return "\(repoName(trimmedTarget)) · Issues"
        }
    }

    private func repoName(_ slug: String) -> String {
        slug.replacingOccurrences(of: "https://github.com/", with: "")
            .split(separator: "/").last.map(String.init) ?? slug
    }

    // MARK: Small styled primitives (SettingsView's are file-private)

    @ViewBuilder private func field<C: View>(_ label: String,
                                             @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Typography.ui(Typography.base))
                .foregroundStyle(p.mutedForeground.color)
                .frame(width: 96, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func textField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Typography.ui(Typography.base))
            .foregroundStyle(p.foreground.color)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(p.input.color))
            .overlay(RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(p.border.color.opacity(Stroke.border), lineWidth: 1))
            .frame(maxWidth: 320)
    }
}
