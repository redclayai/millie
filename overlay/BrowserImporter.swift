import Foundation
import Combine
import SwiftUI

/// One data category the user can import. Bookmarks + History land in Millie's
/// own stores; the rest are decrypted and written into the active Space's
/// Chromium profile by the C++ bridge (MoriImport).
enum ImportDataType: String, CaseIterable, Identifiable {
    case bookmarks, history, passwords, cookies, cards

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bookmarks: return "Bookmarks"
        case .history:   return "History"
        case .passwords: return "Passwords"
        case .cookies:   return "Cookies"
        case .cards:     return "Payment methods"
        }
    }

    var icon: String {
        switch self {
        case .bookmarks: return "bookmark"
        case .history:   return "clock.arrow.circlepath"
        case .passwords: return "key"
        case .cookies:   return "circle.grid.2x2"
        case .cards:     return "creditcard"
        }
    }

    /// True for the categories decrypted with the source browser's Keychain key
    /// (so the UI can warn that a one-time approval prompt may appear).
    var isEncrypted: Bool {
        switch self {
        case .bookmarks, .history: return false
        case .passwords, .cookies, .cards: return true
        }
    }
}

/// A Chromium-family browser detected on disk, with its selectable profiles.
struct DetectedBrowser: Identifiable {
    let id: String        // "chrome", "brave", …
    let name: String      // "Google Chrome"
    let dataDir: String
    let profiles: [Profile]

    struct Profile: Identifiable {
        let dir: String
        let name: String
        var id: String { dir }
    }
}

/// Outcome of an import run, shown on the summary screen.
struct ImportResult {
    var bookmarks = 0
    var history = 0
    var passwords = 0
    var cookies = 0
    var cards = 0
    var errors: [String] = []

    var total: Int { bookmarks + history + passwords + cookies + cards }
}

/// Drives the "Import from your old browser" flow: detect installed browsers,
/// hold the user's browser/profile/type selection, and run the import.
@MainActor
final class BrowserImporter: ObservableObject {
    static let shared = BrowserImporter()

    @Published private(set) var browsers: [DetectedBrowser] = []
    @Published var selectedBrowserID: String?
    @Published var selectedProfileDir: String?
    @Published var selectedTypes: Set<ImportDataType> = Set(ImportDataType.allCases)

    @Published private(set) var running = false
    @Published private(set) var result: ImportResult?

    var selectedBrowser: DetectedBrowser? {
        browsers.first { $0.id == selectedBrowserID }
    }

    /// (Re)scan for installed browsers and pick sensible defaults.
    func detect() {
        let raw = MoriImport.detectBrowsers()
        browsers = raw.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let dataDir = dict["dataDir"] as? String,
                  let profs = dict["profiles"] as? [[String: Any]]
            else { return nil }
            let profiles = profs.compactMap { p -> DetectedBrowser.Profile? in
                guard let dir = p["dir"] as? String,
                      let pname = p["name"] as? String else { return nil }
                return DetectedBrowser.Profile(dir: dir, name: pname)
            }
            guard !profiles.isEmpty else { return nil }
            return DetectedBrowser(id: id, name: name, dataDir: dataDir,
                                   profiles: profiles)
        }
        result = nil
        if selectedBrowser == nil { selectedBrowserID = browsers.first?.id }
        syncProfileDefault()
    }

    func selectBrowser(_ id: String) {
        selectedBrowserID = id
        syncProfileDefault()
    }

    private func syncProfileDefault() {
        let profiles = selectedBrowser?.profiles ?? []
        if !profiles.contains(where: { $0.dir == selectedProfileDir }) {
            selectedProfileDir = profiles.first?.dir
        }
    }

    var canImport: Bool {
        !running && selectedBrowser != nil && selectedProfileDir != nil
            && !selectedTypes.isEmpty
    }

    /// Run the import for the current selection against the given target Millie
    /// profile key (the active Space's profile). Bookmarks/history go through
    /// Millie's Swift stores; encrypted types go through the C++ bridge.
    func runImport(targetProfileKey: String) {
        guard let browser = selectedBrowser,
              let profileDir = selectedProfileDir, !running else { return }
        running = true
        var res = ImportResult()

        if selectedTypes.contains(.bookmarks) {
            let items = MoriImport.readBookmarks(dataDir: browser.dataDir,
                                                 profileDir: profileDir)
            for item in items {
                guard let url = item["url"] as? String,
                      let title = item["title"] as? String else { continue }
                if !BookmarkStore.shared.isBookmarked(url) {
                    BookmarkStore.shared.toggle(url: url, title: title)
                    res.bookmarks += 1
                }
            }
        }

        if selectedTypes.contains(.history) {
            let rows = MoriImport.readHistory(dataDir: browser.dataDir,
                                              profileDir: profileDir, limit: 5000)
            for row in rows {
                guard let url = row["url"] as? String else { continue }
                let title = row["title"] as? String ?? ""
                HistoryStore.shared.record(url: url, title: title)
                res.history += 1
            }
        }

        let encrypted = selectedTypes.filter { $0.isEncrypted }
        if !encrypted.isEmpty {
            let typeKeys = encrypted.map { $0.rawValue }
            let out = MoriImport.importEncrypted(
                dataDir: browser.dataDir, profileDir: profileDir,
                browserId: browser.id, types: typeKeys,
                intoProfileKey: targetProfileKey)
            res.passwords = out["passwords"] as? Int ?? 0
            res.cookies = out["cookies"] as? Int ?? 0
            res.cards = out["cards"] as? Int ?? 0
            res.errors = out["errors"] as? [String] ?? []
        }

        result = res
        running = false
    }
}

extension BrowserStore {
    /// Open the "Import from your old browser" overlay.
    func presentImportPanel() {
        withAnimation(Motion.reveal) { importPanelVisible = true }
    }

    func dismissImportPanel() {
        withAnimation(Motion.reveal) { importPanelVisible = false }
    }
}
