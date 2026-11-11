import SwiftUI

/// A note the user has pinned to a site. Keyed by host, so it follows you across
/// every page on that domain — your running notes on a docs site, a dashboard,
/// a client's app.
struct SiteNote: Codable {
    var host: String
    var text: String
    var updatedAt: Date
}

/// Persistent per-site notes (Ardia parity: "site notes"). Stored as JSON in
/// Application Support, keyed by normalized host. Local to this Mac, like
/// bookmarks.
final class SiteNoteStore: ObservableObject {
    static let shared = SiteNoteStore()

    @Published private(set) var notes: [String: SiteNote] = [:]

    private let fileURL: URL
    private var saveScheduled = false

    init() {
        let fm = FileManager.default
        let dir = BrowserSettings.dataDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("site_notes.json")
        load()
    }

    /// Normalize a page URL to the host the note is filed under. Drops a leading
    /// "www." so the note is shared across www/non-www. Returns nil for pages
    /// that can't carry a note (internal pages, blank, non-web schemes).
    static func host(for urlString: String) -> String? {
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://"),
              let host = URL(string: urlString)?.host, !host.isEmpty
        else { return nil }
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    func text(for urlString: String) -> String {
        guard let host = Self.host(for: urlString) else { return "" }
        return notes[host]?.text ?? ""
    }

    func hasNote(for urlString: String) -> Bool {
        guard let host = Self.host(for: urlString) else { return false }
        return !(notes[host]?.text.isEmpty ?? true)
    }

    func updatedAt(for urlString: String) -> Date? {
        guard let host = Self.host(for: urlString) else { return nil }
        return notes[host]?.updatedAt
    }

    /// Upsert (or clear) the note for the page's host. Empty text removes it.
    func setText(_ text: String, for urlString: String) {
        guard let host = Self.host(for: urlString) else { return }
        let trimmed = text
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if notes[host] != nil {
                notes.removeValue(forKey: host)
                scheduleSave()
            }
            return
        }
        notes[host] = SiteNote(host: host, text: trimmed, updatedAt: Date())
        scheduleSave()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SiteNote].self, from: data)
        else { return }
        notes = decoded
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Omnibox button that opens a scratchpad of notes for the current site. The
/// glyph fills with the accent color when the site already has a note.
struct SiteNoteButton: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var store = SiteNoteStore.shared
    @Environment(\.palette) private var p

    @State private var showPopover = false
    @State private var draft = ""

    private var host: String? { SiteNoteStore.host(for: tab.urlString) }

    var body: some View {
        if host != nil {
            let hasNote = store.hasNote(for: tab.urlString)
            Button {
                draft = store.text(for: tab.urlString)
                showPopover = true
            } label: {
                Icon(name: hasNote ? "note.text" : "note", size: 14)
                    .foregroundStyle(hasNote ? p.accent.color : p.mutedForeground.color)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasNote ? "Site notes" : "Add a note for this site")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                SiteNotePopover(host: host ?? "", draft: $draft) { text in
                    store.setText(text, for: tab.urlString)
                }
            }
        }
    }
}

/// The popover card: a titled scratchpad bound to `draft`, persisting on every
/// edit through `onChange`.
private struct SiteNotePopover: View {
    let host: String
    @Binding var draft: String
    let onChange: (String) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Icon(name: "note.text", size: 12)
                    .foregroundStyle(p.mutedForeground.color)
                Text(host)
                    .font(Typography.ui(Typography.label, weight: .medium))
                    .foregroundStyle(p.foreground.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Jot a note for this site…")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(p.mutedForeground.color.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(Typography.ui(Typography.base))
                    .foregroundStyle(p.foreground.color)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 2)
                    .frame(height: 180)
                    .onChange(of: draft) { _, v in onChange(v) }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(p.input.color.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(p.border.color.opacity(0.6), lineWidth: 1)
            )

            Text("Saved for every page on this site, on this Mac.")
                .font(Typography.ui(Typography.small))
                .foregroundStyle(p.mutedForeground.color)
        }
        .padding(14)
        .frame(width: 320)
        .background(p.popover.color)
    }
}
