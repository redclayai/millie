import SwiftUI

/// Full-tab blocking interstitial shown when a navigation is stopped because the
/// destination is on Millie's phishing / malware blocklist. Covers the active
/// tab's web content and swallows input. "Back to safety" is the primary path;
/// proceeding is tucked behind a disclosure so it isn't a one-tap escape.
struct SafeBrowsingOverlay: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.palette) private var p
    @State private var showProceed = false

    private let danger = Color(red: 0.86, green: 0.29, blue: 0.24)

    var body: some View {
        if let block = store.threatBlock, block.tabID == store.selectedTabID {
            ZStack {
                // Opaque cover so nothing of the blocked page shows or is clickable.
                Rectangle()
                    .fill(Color(red: 0.09, green: 0.10, blue: 0.12))
                    .contentShape(Rectangle())

                VStack(spacing: 16) {
                    Icon(name: "exclamationmark.shield.fill", size: 48)
                        .foregroundStyle(danger)

                    Text("Deceptive site blocked")
                        .font(Typography.ui(Typography.title, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Millie blocked **\(block.host)** because it’s on a known phishing or malware list. It may try to steal passwords or install harmful software.")
                        .font(Typography.ui(Typography.base))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        store.dismissThreatBlock()
                    } label: {
                        Text("Back to safety")
                            .font(Typography.ui(Typography.base, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 9)
                            .background(danger, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if showProceed {
                        Button {
                            store.proceedThroughThreat()
                        } label: {
                            Text("Ignore the warning and continue to \(block.host)")
                                .font(Typography.ui(Typography.label))
                                .foregroundStyle(danger.opacity(0.95))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            withAnimation(Motion.snappy) { showProceed = true }
                        } label: {
                            Text("Details")
                                .font(Typography.ui(Typography.label))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(40)
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }
}
