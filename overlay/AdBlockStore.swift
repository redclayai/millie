import Foundation
import Combine

/// Observable count of ad/tracker requests Millie's built-in blocker has
/// cancelled this session. The C++ throttle (mori_adblock.mm) posts a coalesced
/// `MoriAdBlocked` notification carrying the running total; this republishes it
/// for the Settings readout. Blocking itself is entirely in the network layer —
/// this store is display-only, mirroring how DownloadStore observes the bridge.
@MainActor
final class AdBlockStore: ObservableObject {
    static let shared = AdBlockStore()

    /// Requests blocked since launch.
    @Published private(set) var blockedThisSession: Int = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("MoriAdBlocked"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let count = note.userInfo?["count"] as? Int else { return }
            self?.blockedThisSession = count
        }
    }
}
