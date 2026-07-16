import Foundation
import Combine

/// Swift-side state for Millie's built-in ad/tracker blocker. Blocking itself
/// is entirely in the network layer (mori_adblock.mm); this store mirrors two
/// pieces of it for the UI:
/// - the running blocked count (the C++ proxy posts a coalesced `MoriAdBlocked`
///   notification; republished for the Settings readout), and
/// - the per-site allowlist ("Don't block ads on this site"), persisted in the
///   same defaults key the C++ side reads at startup and pushed to the engine
///   on every change so toggling applies without a relaunch.
@MainActor
final class AdBlockStore: ObservableObject {
    static let shared = AdBlockStore()

    /// Requests blocked since launch.
    @Published private(set) var blockedThisSession: Int = 0

    /// Hosts excluded from ad blocking, normalized like SiteBrand.host
    /// (lowercase, no trailing dot, no leading "www.").
    @Published private(set) var allowedHosts: Set<String>

    private static let allowlistKey = "mori.adblockAllowlist"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.allowlistKey) ?? []
        allowedHosts = Set(saved.compactMap(Self.normalize))

        NotificationCenter.default.addObserver(
            forName: Notification.Name("MoriAdBlocked"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let count = note.userInfo?["count"] as? Int else { return }
            // The observer is registered on `.main`, so this always runs on the
            // main actor — assert it so the mutation is concurrency-clean.
            MainActor.assumeIsolated {
                self?.blockedThisSession = count
            }
        }
    }

    func isAllowed(host: String) -> Bool {
        guard let h = Self.normalize(host) else { return false }
        return allowedHosts.contains(h)
    }

    func setAllowed(_ allowed: Bool, host: String) {
        guard let h = Self.normalize(host) else { return }
        if allowed {
            allowedHosts.insert(h)
        } else {
            allowedHosts.remove(h)
        }
        UserDefaults.standard.set(allowedHosts.sorted(), forKey: Self.allowlistKey)
        MoriBrowserView.setAdBlockerAllowedHosts(Array(allowedHosts))
    }

    /// Must match NormalizeHost in mori_adblock.mm so the Swift toggle state
    /// and the engine's per-request check agree.
    private static func normalize(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }
}
