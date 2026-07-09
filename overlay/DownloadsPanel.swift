import SwiftUI

/// The downloads control in the header: a pill that is BOTH the live download
/// indicator and the dropdown trigger. It fills blue left→right as active
/// downloads progress (fully blue briefly on completion); tapping it opens the
/// Downloads popover. Hidden until the first download, then persists as the
/// dropdown button (grey with ↓/chevron) when idle.
struct DownloadsButton: View {
    @ObservedObject var downloads: DownloadStore
    @Binding var isOpen: Bool
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var completionHold = false   // hold at full-blue briefly on finish
    @State private var slide = false            // indeterminate sweep

    private let w: CGFloat = 40       // overall control width
    private let barW: CGFloat = 34    // progress-bar width
    private let barH: CGFloat = 6

    private var active: Bool { downloads.hasActiveDownloads }
    private var showProgress: Bool { active || completionHold }
    private var indeterminate: Bool { downloads.hasIndeterminateActive && !completionHold }

    /// Blue fill for known-size downloads: a dot at the start, growing to the
    /// full bar at 100% (and on completion).
    private var fillWidth: CGFloat {
        let f = completionHold ? 1.0 : downloads.aggregateFraction
        return min(barW, max(barH, barW * CGFloat(f)))
    }

    var body: some View {
        if downloads.items.isEmpty {
            EmptyView()
        } else {
            Button { isOpen.toggle() } label: { pill }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : Motion.reveal, value: fillWidth)
                .animation(Motion.snappy, value: showProgress)
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    DownloadsPanel(downloads: downloads)
                        .environment(\.palette, p)
                }
                .help(active ? "Downloading…" : "Downloads")
                .onChange(of: downloads.completionToken) { _, _ in
                    guard !downloads.hasActiveDownloads else { return }
                    completionHold = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        if !downloads.hasActiveDownloads { completionHold = false }
                    }
                }
                .onChange(of: indeterminate) { _, ind in driveSlide(ind) }
                .onAppear { driveSlide(indeterminate) }
        }
    }

    private var pill: some View {
        VStack(spacing: 3) {
            // ↓ download + ⌄ dropdown icons, spread across the bar width.
            HStack(spacing: 0) {
                Icon(name: "arrow.down", size: 12)
                Spacer(minLength: 0)
                Icon(name: "chevron.down", size: 9)
            }
            .foregroundStyle(p.sidebarForeground.color.opacity(isOpen ? 1 : 0.8))
            .frame(width: barW)
            // Progress bar: grey track, blue fill from the left = download progress.
            ZStack(alignment: .leading) {
                Capsule().fill(p.mutedForeground.color.opacity(0.3))
                if showProgress {
                    if indeterminate {
                        Capsule().fill(p.primary.color)
                            .frame(width: barW * 0.4)
                            .offset(x: slide ? barW * 0.6 : 0)
                    } else {
                        Capsule().fill(p.primary.color).frame(width: fillWidth)
                    }
                }
            }
            .frame(width: barW, height: barH)
            .clipped()
        }
        .frame(width: w)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func driveSlide(_ on: Bool) {
        guard !reduceMotion else { slide = false; return }
        if on {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                slide = true
            }
        } else {
            withAnimation(.default) { slide = false }
        }
    }
}

/// The Downloads popover: a list of in-flight and finished downloads with
/// progress, reveal/open actions, and a clear button. Driven by `DownloadStore`.
struct DownloadsPanel: View {
    @ObservedObject var downloads: DownloadStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline().opacity(0.6)
            if downloads.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
        .background(p.popover.color)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Downloads")
                .font(Typography.ui(Typography.title, weight: .semibold))
                .foregroundStyle(p.foreground.color)
            Spacer()
            Button { downloads.showDefaultFolder() } label: {
                Text("Folder")
                    .font(Typography.ui(Typography.label, weight: .medium))
                    .foregroundStyle(p.mutedForeground.color)
            }
            .buttonStyle(.plain)
            if downloads.items.contains(where: { $0.isComplete || $0.isCanceled }) {
                Button { downloads.clearFinished() } label: {
                    Text("Clear")
                        .font(Typography.ui(Typography.label, weight: .medium))
                        .foregroundStyle(p.mutedForeground.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Icon(name: "tray.and.arrow.down", size: 30, weight: .light)
                .foregroundStyle(p.mutedForeground.color)
            Text("No downloads yet")
                .font(Typography.ui(Typography.base))
                .foregroundStyle(p.mutedForeground.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(downloads.items) { item in
                    DownloadRow(item: item, downloads: downloads)
                }
            }
            .padding(8)
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var downloads: DownloadStore
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Icon(name: icon, size: 20, weight: .regular)
                .foregroundStyle(item.isComplete ? p.primary.color : p.mutedForeground.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                if !item.displayName.isEmpty {
                    Text(item.displayName)
                        .font(Typography.ui(Typography.base, weight: .medium))
                        .foregroundStyle(p.foreground.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if item.isInProgress && !item.isComplete && !item.isCanceled {
                    ProgressView(value: min(max(item.fractionComplete, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(p.primary.color)
                        .frame(height: 4)
                }

                Text(item.statusText)
                    .font(Typography.ui(Typography.small))
                    .foregroundStyle(p.mutedForeground.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if item.isInProgress && !item.isComplete && !item.isCanceled {
                Button { downloads.cancel(item) } label: {
                    Icon(name: "xmark", size: 14, weight: .semibold)
                        .foregroundStyle(p.mutedForeground.color)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
                .opacity(hovering ? 1 : 0)
            } else if item.isComplete {
                Button { downloads.reveal(item) } label: {
                    Icon(name: "magnifyingglass", size: 14)
                        .foregroundStyle(p.mutedForeground.color)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(hovering ? TabSurface.hoverFill(scheme) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.state, value: hovering)
        .onTapGesture(count: 2) { downloads.open(item) }
    }

    private var icon: String {
        if item.isCanceled { return "xmark.circle" }
        if item.isComplete { return "doc.fill" }
        return "arrow.down.circle"
    }
}
