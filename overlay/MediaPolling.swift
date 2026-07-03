import SwiftUI

/// Drives the sidebar media player and Picture-in-Picture by sampling each live
/// tab's injected media agent (see MediaAgentScripts.swift). Unlike the old CEF
/// build's push channel, the overlay pulls: a low-frequency timer reads
/// `window.__moriMediaState()` from Millie's isolated media world in every awake
/// tab and rebroadcasts it as the `MoriMediaUpdated` notification that
/// `MediaController` already consumes.
extension BrowserStore {
    /// How often each live tab's media agent is sampled. Fast enough for the
    /// sidebar scrubber to feel live, coarse enough to stay cheap.
    private static let mediaPollInterval: TimeInterval = 1.0

    func startMediaPolling() {
        mediaPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.mediaPollInterval,
                                         repeats: true) { [weak self] _ in
            self?.pollMediaState()
            self?.pollWebStoreInstall()
        }
        timer.tolerance = 0.3
        mediaPollTimer = timer
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

    /// Pull each awake tab's media snapshot and rebroadcast it. Asleep tabs are
    /// skipped so polling never resurrects a freed browser.
    private func pollMediaState() {
        for tab in tabs where tab.hasRealized && !tab.isAsleep {
            let browserId = Int(tab.browserView.browserIdentifier)
            Task { @MainActor in
                guard
                    let result = try? await tab.evaluateMediaJavaScript(
                        "window.__moriMediaState ? window.__moriMediaState() : ''"),
                    let json = result as? String, !json.isEmpty
                else { return }
                NotificationCenter.default.post(
                    name: Notification.Name("MoriMediaUpdated"),
                    object: nil,
                    userInfo: ["browserId": browserId, "json": json])
            }
        }
    }
}
