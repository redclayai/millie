import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Thin wrapper around Sparkle so Millie updates itself like a normal browser.
/// The update feed + signing key come from the app's Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`), written by release.sh. Everything is `#if canImport`-guarded
/// so a build without the Sparkle framework still compiles and simply no-ops.
@MainActor
final class MillieUpdater {
    static let shared = MillieUpdater()

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif

    /// Whether auto-update support is compiled into this build.
    var isAvailable: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    /// Start the updater and its scheduled background checks. Call once at launch.
    /// No-op if there's no feed configured (e.g. an unsigned local dev build).
    func start() {
        #if canImport(Sparkle)
        guard controller == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            return  // No appcast configured (dev build) — don't start Sparkle.
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    /// User-initiated check ("Check for Updates…"). Shows Sparkle's progress and
    /// install UI. Falls back to opening the releases page if Sparkle isn't set up.
    func checkForUpdates() {
        #if canImport(Sparkle)
        if controller == nil { start() }
        controller?.checkForUpdates(nil)
        #endif
    }
}

/// Hourly poller for new Millie releases, independent of Sparkle's own cadence:
/// fetches the GitHub appcast, compares the newest version against the running
/// build, and publishes it for the sidebar's bottom-bar update chip. Clicking
/// the chip hands off to Sparkle (`MillieUpdater.checkForUpdates`).
@MainActor
final class UpdateNotifier: ObservableObject {
    static let shared = UpdateNotifier()

    /// Newer version available on GitHub (e.g. "2.27"), nil when up to date.
    @Published private(set) var availableVersion: String?

    private var timer: Timer?
    private var dismissedVersion: String? =
        UserDefaults.standard.string(forKey: "mori.updateDismissedVersion")

    private static let pollInterval: TimeInterval = 3600
    /// Appcast from Info.plist (release builds), falling back to the canonical
    /// GitHub URL so dev builds poll too.
    private var feedURL: URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
            ?? "https://github.com/redclayai/millie/releases/latest/download/appcast.xml"
        return URL(string: raw)
    }

    /// Begin hourly polling (plus one immediate check). Idempotent.
    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        t.tolerance = 300
        timer = t
        Task { await poll() }
    }

    /// Hide the chip for this version (until an even newer one appears).
    func dismiss() {
        dismissedVersion = availableVersion
        UserDefaults.standard.set(dismissedVersion, forKey: "mori.updateDismissedVersion")
        availableVersion = nil
    }

    private func poll() async {
        guard let url = feedURL else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              let xml = String(data: data, encoding: .utf8) else { return }
        guard let latest = Self.newestVersion(inAppcast: xml) else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
        if Self.isVersion(latest, newerThan: current), latest != dismissedVersion {
            availableVersion = latest
        } else if !Self.isVersion(latest, newerThan: current) {
            availableVersion = nil
        }
    }

    /// Highest `sparkle:shortVersionString` in the appcast (element or
    /// attribute form).
    static func newestVersion(inAppcast xml: String) -> String? {
        var versions: [String] = []
        for pattern in [
            "<sparkle:shortVersionString>([0-9][0-9.]*)</sparkle:shortVersionString>",
            "sparkle:shortVersionString=\"([0-9][0-9.]*)\"",
        ] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(xml.startIndex..., in: xml)
            for m in re.matches(in: xml, range: range) {
                if let r = Range(m.range(at: 1), in: xml) { versions.append(String(xml[r])) }
            }
        }
        return versions.max { isVersion($1, newerThan: $0) }
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
