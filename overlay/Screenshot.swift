import SwiftUI
import AppKit

// MARK: - Store coordination & capture

extension BrowserStore {
    /// Arm the drag-to-select region capture overlay.
    func startRegionCapture() {
        guard !captureMode else { return }
        // Other transient overlays would be captured/obscured; clear them.
        dismissWebContextMenu()
        withAnimation(Motion.snappy) { captureMode = true }
        ToastCenter.shared.show("Drag to capture · Esc to cancel",
                                icon: "camera.viewfinder", style: .info, duration: 3)
    }

    func cancelRegionCapture() {
        guard captureMode else { return }
        withAnimation(Motion.snappy) { captureMode = false }
    }

    /// Called by the overlay with the selected rect (points, top-left in the
    /// window's content space).
    func finishRegionCapture(_ rect: CGRect) {
        withAnimation(Motion.snappy) { captureMode = false }
        guard rect.width > 4, rect.height > 4 else { return }
        // Let SwiftUI tear the overlay down before grabbing the window, so the
        // dim/selection chrome isn't baked into the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            self?.performRegionCapture(rect)
        }
    }

    private func performRegionCapture(_ rect: CGRect) {
        guard let window = captureWindow(),
              let full = Self.captureWindowImage(window) else {
            ToastCenter.shared.show("Couldn't capture the window", icon: "xmark", style: .warning)
            return
        }
        let scale = window.backingScaleFactor
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                        width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !px.isNull, px.width > 1, px.height > 1,
              let cropped = full.cropping(to: px) else { return }
        Self.deliver(cropped)
    }

    /// Capture just the active tab's visible web content (the viewport).
    func captureVisibleArea() {
        guard let tab = selectedTab, tab.hasRealized else {
            ToastCenter.shared.show("Nothing to capture", icon: "camera", style: .warning)
            return
        }
        let view = tab.browserView
        guard let window = view.window, let full = Self.captureWindowImage(window) else {
            ToastCenter.shared.show("Couldn't capture the page", icon: "xmark", style: .warning)
            return
        }
        let scale = window.backingScaleFactor
        let contentH = window.contentView?.bounds.height ?? window.frame.height
        // Web view bounds → window coords (bottom-left) → top-left points.
        let inWindow = view.convert(view.bounds, to: nil)
        let topLeft = CGRect(x: inWindow.minX, y: contentH - inWindow.maxY,
                             width: inWindow.width, height: inWindow.height)
        let px = CGRect(x: topLeft.minX * scale, y: topLeft.minY * scale,
                        width: topLeft.width * scale, height: topLeft.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !px.isNull, let cropped = full.cropping(to: px) else { return }
        Self.deliver(cropped)
    }

    /// Capture the ENTIRE scrollable page (not just the viewport) by scrolling
    /// through it a viewport at a time, grabbing each frame, and stitching them
    /// into one tall image. Chromium has no one-shot full-page capture we can
    /// reach from the overlay, so this is a scroll-and-stitch. Fixed/sticky
    /// headers repeat across slices — a known limitation of this approach.
    func captureFullPage() {
        guard let tab = selectedTab, tab.hasRealized,
              tab.urlString.hasPrefix("http") else {
            ToastCenter.shared.show("Nothing to capture", icon: "camera", style: .warning)
            return
        }
        ToastCenter.shared.show("Capturing full page…", icon: "camera.viewfinder",
                                style: .info, duration: 2)
        Task { @MainActor in await self.runFullPageCapture(tab) }
    }

    @MainActor
    private func runFullPageCapture(_ tab: BrowserTab) async {
        let view = tab.browserView
        guard let window = view.window else { captureVisibleArea(); return }
        let scale = window.backingScaleFactor

        let metricsJS = """
        JSON.stringify((function(){
          var de = document.documentElement, b = document.body || de;
          return { pageH: Math.max(de.scrollHeight, b.scrollHeight, de.clientHeight),
                   vw: window.innerWidth, vh: window.innerHeight,
                   sx: window.pageXOffset, sy: window.pageYOffset }; })())
        """
        guard let m = await Self.evalNumbers(tab, metricsJS),
              let pageH = m["pageH"], let vh = m["vh"], let vw = m["vw"],
              let origSy = m["sy"], let origSx = m["sx"], vh > 1, pageH > 1 else {
            captureVisibleArea(); return
        }
        // Cap runaway pages (~40 screens) so a broken layout can't hang capture.
        let totalH = min(pageH, vh * 40)
        let steps = max(1, Int(ceil(totalH / vh)))

        let pxW = Int((vw * scale).rounded()), pxH = Int((totalH * scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            captureVisibleArea(); return
        }
        rep.size = NSSize(width: vw, height: totalH)

        // Hide scrollbars while capturing so they don't streak the stitch.
        _ = try? await tab.evaluateJavaScript(
            "document.documentElement.style.overflow='hidden';")

        for i in 0..<steps {
            let y = Double(i) * vh
            _ = try? await tab.evaluateJavaScript("window.scrollTo(0,\(y));")
            try? await Task.sleep(nanoseconds: 200_000_000)  // let it paint
            guard let full = Self.captureWindowImage(window),
                  let vpCG = Self.cropWebView(view, from: full, scale: scale) else { continue }
            let vpImage = NSImage(cgImage: vpCG, size: NSSize(width: vw, height: vh))
            let sliceH = min(vh, totalH - y)             // last row may be partial
            let dest = NSRect(x: 0, y: totalH - (y + sliceH), width: vw, height: sliceH)
            let src = NSRect(x: 0, y: vh - sliceH, width: vw, height: sliceH)  // top of viewport
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            vpImage.draw(in: dest, from: src, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        _ = try? await tab.evaluateJavaScript(
            "document.documentElement.style.overflow='';window.scrollTo(\(origSx),\(origSy));")

        guard let cg = rep.cgImage else { captureVisibleArea(); return }
        Self.deliver(cg)
    }

    /// Run a JS snippet returning a JSON object of numbers; parse to [String:Double].
    private static func evalNumbers(_ tab: BrowserTab, _ js: String) async -> [String: Double]? {
        guard let raw = try? await tab.evaluateJavaScript(js),
              let str = raw as? String, let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var out: [String: Double] = [:]
        for (k, v) in obj { if let n = v as? NSNumber { out[k] = n.doubleValue } }
        return out
    }

    /// Crop the web view's region (in device pixels) out of a full-window grab.
    private static func cropWebView(_ view: NSView, from full: CGImage,
                                    scale: CGFloat) -> CGImage? {
        guard let window = view.window else { return nil }
        let contentH = window.contentView?.bounds.height ?? window.frame.height
        let inWindow = view.convert(view.bounds, to: nil)
        let topLeft = CGRect(x: inWindow.minX, y: contentH - inWindow.maxY,
                             width: inWindow.width, height: inWindow.height)
        let px = CGRect(x: topLeft.minX * scale, y: topLeft.minY * scale,
                        width: topLeft.width * scale, height: topLeft.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !px.isNull, px.width > 1, px.height > 1 else { return nil }
        return full.cropping(to: px)
    }

    /// Present the native macOS share sheet for the current page URL, anchored to
    /// the top-trailing corner of the content area.
    func shareCurrentPage() {
        guard let tab = selectedTab, tab.urlString.hasPrefix("http"),
              let url = URL(string: tab.urlString) else {
            ToastCenter.shared.show("Nothing to share", icon: "square.and.arrow.up",
                                    style: .warning)
            return
        }
        guard let window = tab.browserView.window ?? NSApp.keyWindow,
              let content = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: content.bounds.maxX - 44, y: content.bounds.maxY - 44,
                            width: 1, height: 1)
        picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
    }

    private func captureWindow() -> NSWindow? {
        selectedTab?.browserView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// Grab the composited image of our own window (no screen-recording
    /// permission needed for one's own windows).
    private static func captureWindowImage(_ window: NSWindow) -> CGImage? {
        let windowID = CGWindowID(window.windowNumber)
        guard windowID != 0 else { return nil }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution])
    }

    /// Copy the capture to the clipboard and save a PNG to the Desktop.
    private static func deliver(_ cg: CGImage) {
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])

        var savedNote = "copied"
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            let fm = FileManager.default
            let dir = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let name = "Millie Shot \(formatter.string(from: Date())).png"
            if (try? data.write(to: dir.appendingPathComponent(name))) != nil {
                savedNote = "copied & saved to Desktop"
            }
        }
        ToastCenter.shared.show("Screenshot \(savedNote)", icon: "camera", style: .success)
    }
}

// MARK: - Region selection overlay
//
// AppKit-hosted (like LauncherOverlay) so the selection surface sits above the
// live web view and actually receives the drag — a plain SwiftUI `.overlay`
// would render behind the CEF content and never see the gesture.

struct CaptureOverlay: NSViewRepresentable {
    @ObservedObject var store: BrowserStore

    func makeNSView(context: Context) -> CaptureContainerView {
        let view = CaptureContainerView()
        view.update(store: store)
        return view
    }

    func updateNSView(_ nsView: CaptureContainerView, context: Context) {
        nsView.update(store: store)
    }
}

final class CaptureContainerView: NSView {
    private var hosting: NSHostingView<AnyView>?
    private weak var store: BrowserStore?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        hosting = host
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update(store: BrowserStore) {
        self.store = store
        rebuild()
    }

    private func rebuild() {
        guard let store else { return }
        hosting?.rootView = AnyView(
            Group {
                if store.captureMode {
                    CaptureSelectionView(store: store)
                        .frame(width: max(bounds.width, 1), height: max(bounds.height, 1))
                }
            }
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard store?.captureMode == true else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        hosting?.frame = bounds
        rebuild()
    }
}

private struct CaptureSelectionView: View {
    @ObservedObject var store: BrowserStore
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    if let rect = selectionRect {
                        // Punch-through highlight of the chosen region.
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: rect.width, height: rect.height)
                            .overlay(
                                Rectangle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                            )
                            .position(x: rect.midX, y: rect.midY)
                    }
                    if selectionRect == nil {
                        Text("Drag to capture a region")
                            .font(Typography.ui(13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .local)
                        .onChanged { v in
                            if start == nil { start = v.startLocation }
                            current = v.location
                        }
                        .onEnded { v in
                            let rect = Self.rect(from: start ?? v.startLocation, to: v.location)
                            start = nil
                            current = nil
                            store.finishRegionCapture(rect)
                        }
                )
        }
    }

    private var selectionRect: CGRect? {
        guard let start, let current else { return nil }
        return Self.rect(from: start, to: current)
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
