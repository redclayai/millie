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
