import SwiftUI

/// Drives the sidebar media player and Picture-in-Picture by sampling each live
/// tab's injected media agent (see MediaAgentScripts.swift). Unlike the old CEF
/// build's push channel, the overlay pulls: a low-frequency timer reads
/// `window.__moriMediaState()` from Millie's isolated media world in every awake
/// tab and rebroadcasts it as the `MoriMediaUpdated` notification that
/// `MediaController` already consumes.
extension BrowserStore {
    /// Fast cadence while media is playing — keeps the sidebar scrubber live.
    private static let mediaPollFast: TimeInterval = 1.0
    /// Slow cadence while nothing is playing — just enough to notice a tab that
    /// starts media in the background.
    private static let mediaPollSlow: TimeInterval = 4.0
    /// Every Nth tick, re-scan ALL awake tabs (not just known-media ones) so a
    /// freshly-started background video is picked up.
    private static let mediaRescanEvery = 3

    func startMediaPolling() {
        scheduleMediaTimer(fast: false)
    }

    private func scheduleMediaTimer(fast: Bool) {
        mediaPollTimer?.invalidate()
        mediaPollFast = fast
        let interval = fast ? Self.mediaPollFast : Self.mediaPollSlow
        let timer = Timer.scheduledTimer(withTimeInterval: interval,
                                         repeats: true) { [weak self] _ in
            self?.runMediaPoll()
        }
        timer.tolerance = fast ? 0.3 : 1.0
        mediaPollTimer = timer
    }

    private func runMediaPoll() {
        pollMediaState()
        pollWebStoreInstall()

        // Drop media tabs that were closed/slept (otherwise a closed video tab
        // would pin the poller to the fast cadence forever), then switch
        // cadence when the playing/idle state flips.
        mediaActiveTabIDs = mediaActiveTabIDs.filter { id in
            tabs.contains { $0.id == id && $0.hasRealized && !$0.isAsleep }
        }
        let active = !mediaActiveTabIDs.isEmpty
            || tabs.contains { $0.hasRealized && !$0.isAsleep && $0.isAudible }
        if active != mediaPollFast {
            scheduleMediaTimer(fast: active)
        }
    }

    /// On a Chrome Web Store extension page, pick up a click on the enhanced
    /// "Add to Millie" button and route it to the same installer the pill uses
    /// (so per-profile targeting is correct). Only evaluates on store pages.
    private func pollWebStoreInstall() {
        guard let tab = selectedTab, tab.hasRealized, !tab.isAsleep,
              ExtensionStore.webStoreExtensionID(from: tab.urlString) != nil else { return }
        Task { @MainActor in
            guard let id = await tab.readWebStoreInstallRequest() else { return }
            ExtensionStore.shared.beginWebStoreInstall(extensionID: id)
        }
    }

    /// Pull awake tabs' media snapshots and rebroadcast them. To stay cheap on a
    /// busy window, only tabs that recently reported media (plus audible tabs and
    /// the selected tab) are sampled each tick; every `mediaRescanEvery` ticks we
    /// re-scan all awake tabs so newly-started background media is picked up.
    /// Asleep tabs are always skipped so polling never resurrects a freed browser.
    private func pollMediaState() {
        mediaPollTick &+= 1
        let rescan = mediaPollTick % Self.mediaRescanEvery == 0
        for tab in tabs where tab.hasRealized && !tab.isAsleep {
            let sample = rescan
                || tab.isAudible
                || tab.id == selectedTabID
                || mediaActiveTabIDs.contains(tab.id)
            guard sample else { continue }
            let id = tab.id
            let browserId = Int(tab.browserView.browserIdentifier)
            Task { @MainActor in
                let result = try? await tab.evaluateMediaJavaScript(
                    "window.__moriMediaState ? window.__moriMediaState() : ''")
                let json = (result as? String) ?? ""
                if json.isEmpty {
                    self.mediaActiveTabIDs.remove(id)
                    return
                }
                self.mediaActiveTabIDs.insert(id)
                NotificationCenter.default.post(
                    name: Notification.Name("MoriMediaUpdated"),
                    object: nil,
                    userInfo: ["browserId": browserId, "json": json])
            }
        }
    }
}
