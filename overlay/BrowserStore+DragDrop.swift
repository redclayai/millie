import SwiftUI
import UniformTypeIdentifiers

enum SidebarTabDrag {
    static let acceptedTypes: [UTType] = [.plainText, .text]

    static func provider(for id: BrowserTab.ID) -> NSItemProvider {
        NSItemProvider(object: id.uuidString as NSString)
    }
}

/// Where a dragged sidebar tab should land. Indices are clamped by `moveTab`, so
/// a large value (e.g. `Int.max`) means "append".
enum TabDropTarget: Equatable {
    /// Insert into the pinned grid at this index.
    case pinned(index: Int)
    /// Insert into the given folder at this index (`Int.max` appends).
    case folder(id: TabFolder.ID, index: Int)
    /// Place at this position in the mixed ROOT list (`rootOrder` entry index —
    /// tabs and folders share one list, so a tab can land between folders).
    case loose(index: Int)
}

extension BrowserStore {
    /// Move a tab to a sidebar drop target, detaching it from whatever container
    /// it currently lives in first. Drives the live drag-and-drop reordering in
    /// the sidebar.
    ///
    /// Note: this intentionally does not emit `chrome.tabs.onMoved` extension
    /// events. Only the `.loose` branch touches the global `tabs` array, and
    /// sidebar organization (pin / folder membership / loose order) is a Millie
    /// concept that does not map cleanly onto the flat extension tab index.
    func moveTab(_ id: BrowserTab.ID, to target: TabDropTarget) {
        guard tabs.contains(where: { $0.id == id }) else { return }

        let sourcePinnedIndex = pinnedTabIDs.firstIndex(of: id)
        let sourceFolderIndex = folders.firstIndex { $0.tabIDs.contains(id) }
        let sourceFolderID = sourceFolderIndex.map { folders[$0].id }
        let sourceFolderTabIndex = sourceFolderIndex.flatMap { folders[$0].tabIDs.firstIndex(of: id) }
        // (Root-list source position is derived inside the .loose branch.)

        withAnimation(Motion.snappy) {
            // 1. Detach from the current container.
            pinnedTabIDs.removeAll { $0 == id }
            for i in folders.indices {
                folders[i].tabIDs.removeAll { $0 == id }
            }

            // 2. Apply the target.
            switch target {
            case .pinned(let index):
                let adjusted = adjustedInsertionIndex(index, movingFrom: sourcePinnedIndex)
                let clamped = min(max(adjusted, 0), pinnedTabIDs.count)
                pinnedTabIDs.insert(id, at: clamped)

            case .folder(let fid, let index):
                guard let fi = folders.firstIndex(where: { $0.id == fid }) else { return }
                let sourceIndex = sourceFolderID == fid ? sourceFolderTabIndex : nil
                let adjusted = adjustedInsertionIndex(index, movingFrom: sourceIndex)
                let clamped = min(max(adjusted, 0), folders[fi].tabIDs.count)
                folders[fi].tabIDs.insert(id, at: clamped)
                folders[fi].isExpanded = true
                // Remember the URL it was dropped in at, for the folder-icon reset.
                if let t = tab(for: id), t.folderHomeURL == nil {
                    t.folderHomeURL = t.urlString
                }

            case .loose(let index):
                // The tab is now loose (removed from pinned/folders above).
                // Place it at the requested position in the MIXED root list —
                // tabs and folders share this order, so a tab can sit between
                // two folders.
                var entries = healedRootEntries(for: activeContext)
                let sourceIndex = entries.firstIndex(of: .tab(id))
                entries.removeAll { $0 == .tab(id) }
                let adjusted = adjustedInsertionIndex(index, movingFrom: sourceIndex)
                let clamped = min(max(adjusted, 0), entries.count)
                entries.insert(.tab(id), at: clamped)
                contexts[activeContextIndex].rootOrder = entries
            }
            // Pinning/foldering removes the tab from the root list; healing the
            // stored order here keeps it canonical for the next reads.
            if case .loose = target {} else {
                contexts[activeContextIndex].rootOrder =
                    healedRootEntries(for: activeContext)
            }
            syncChromePinnedState(for: id)
            scheduleSessionSave()
        }
    }
}

/// A reusable live-reordering drop delegate. As the dragged tab hovers over a
/// target element it is moved there immediately (animated), so the sidebar
/// rearranges under the cursor.
struct TabReorderDropDelegate: DropDelegate {
    /// Where the dragged tab should go if it is dropped on (or hovered over) THIS
    /// element.
    let target: TabDropTarget
    @Binding var draggingID: BrowserTab.ID?
    let store: BrowserStore
    /// Optional highlight flag for containers that want to show they're the
    /// active drop target (e.g. a folder row).
    var isTargeted: Binding<Bool>? = nil
    /// Large sidebar/chrome catch zones should accept a release without yanking
    /// the tab around while the user is only passing through them.
    var moveOnEnter = true

    /// When set (per-tab rows), dropping in the row's vertical center splits the
    /// dragged tab with THIS tab instead of reordering. The edges still reorder.
    var splitTargetID: BrowserTab.ID? = nil
    /// Row height, so the center "split" band can be measured from `info`.
    var rowHeight: CGFloat = 38
    /// Shared highlight: set to the target tab id while the cursor is in its
    /// split band, so the row can show a "drop to split" ring.
    var splitHover: Binding<BrowserTab.ID?>? = nil

    /// Cursor is in the middle ~44% of the row → a split, not a reorder.
    private func inSplitBand(_ info: DropInfo) -> Bool {
        guard splitTargetID != nil else { return false }
        let y = info.location.y
        return y > rowHeight * 0.28 && y < rowHeight * 0.72
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let sid = splitTargetID, inSplitBand(info) {
            splitHover?.wrappedValue = sid
        } else if splitTargetID != nil {
            if splitHover?.wrappedValue == splitTargetID { splitHover?.wrappedValue = nil }
            // Left the center band → resume live reordering.
            if moveOnEnter {
                resolveDraggedTabID(from: info) {
                    move($0, clearingDragState: false, allowContainerChange: false)
                }
            }
        }
        return DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
        // In the split band, don't reorder — just arm the split highlight.
        if let sid = splitTargetID, inSplitBand(info) {
            splitHover?.wrappedValue = sid
            return
        }
        guard moveOnEnter else { return }
        // Hover only reorders WITHIN the tab's current container. Moving it to a
        // different container (loose → pinned, loose → folder, …) happens only on
        // release — otherwise a folder sitting on the way to the pinned grid
        // steals the tab as the drag passes over it.
        resolveDraggedTabID(from: info) { id in
            move(id, clearingDragState: false, allowContainerChange: false)
        }
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
        if splitHover?.wrappedValue == splitTargetID { splitHover?.wrappedValue = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Drop in the center band → split the two tabs; otherwise reorder.
        if let sid = splitTargetID, inSplitBand(info) {
            splitHover?.wrappedValue = nil
            let dragged = draggingID
            resolveDraggedTabID(from: info) { id in
                if let id = id ?? dragged { store.splitTabs(id, with: sid) }
                draggingID = nil
                isTargeted?.wrappedValue = false
            }
            return true
        }
        // Commit the move here too: `dropEntered` gives live reordering while the
        // cursor moves, but it can miss (small targets, layout shifting under the
        // pointer as a folder expands). Releasing always lands the tab.
        resolveDraggedTabID(from: info) { id in
            move(id, clearingDragState: true)
        }
        return true
    }

    private func resolveDraggedTabID(from info: DropInfo,
                                     completion: @escaping (BrowserTab.ID?) -> Void) {
        if let draggingID {
            completion(draggingID)
            return
        }

        guard let provider = info.itemProviders(for: SidebarTabDrag.acceptedTypes).first else {
            completion(nil)
            return
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            let id = (object as? String)
                .flatMap { BrowserTab.ID(uuidString: $0) }
            DispatchQueue.main.async {
                completion(id)
            }
        }
    }

    private func move(_ id: BrowserTab.ID?, clearingDragState: Bool,
                      allowContainerChange: Bool = true) {
        defer {
            if clearingDragState { draggingID = nil }
            if clearingDragState { isTargeted?.wrappedValue = false }
        }

        guard let id else { return }
        if !allowContainerChange, !store.isInContainer(id, of: target) {
            return
        }
        if !store.isAlready(id, at: target) {
            store.moveTab(id, to: target)
        }
    }
}

extension BrowserStore {
    /// True if `id` already lives in `target`'s container (the pinned grid, the
    /// same folder, or the loose list) — i.e. a move there is a reorder, not a
    /// container change. Hover-moves are restricted to this case.
    func isInContainer(_ id: BrowserTab.ID, of target: TabDropTarget) -> Bool {
        switch target {
        case .pinned:
            return pinnedTabIDs.contains(id)
        case .folder(let fid, _):
            return folders.first(where: { $0.id == fid })?.tabIDs.contains(id) ?? false
        case .loose:
            return looseTabs.contains { $0.id == id }
        }
    }

    /// True if `id` already occupies `target`, so a hover move would be a no-op
    /// (avoids churn / flicker during live reordering).
    func isAlready(_ id: BrowserTab.ID, at target: TabDropTarget) -> Bool {
        switch target {
        case .pinned(let index):
            guard let current = pinnedTabIDs.firstIndex(of: id) else { return false }
            let adjusted = adjustedInsertionIndex(index, movingFrom: current)
            return current == clampedIndex(adjusted, count: max(pinnedTabIDs.count - 1, 0))
        case .folder(let fid, let index):
            guard let folder = folders.first(where: { $0.id == fid }) else { return false }
            guard let current = folder.tabIDs.firstIndex(of: id) else { return false }
            let adjusted = adjustedInsertionIndex(index, movingFrom: current)
            return current == clampedIndex(adjusted, count: max(folder.tabIDs.count - 1, 0))
        case .loose(let index):
            let entries = rootEntries
            guard let current = entries.firstIndex(of: .tab(id)) else { return false }
            let adjusted = adjustedInsertionIndex(index, movingFrom: current)
            return current == clampedIndex(adjusted, count: max(entries.count - 1, 0))
        }
    }

    private func clampedIndex(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count)
    }

    private func adjustedInsertionIndex(_ index: Int, movingFrom sourceIndex: Int?) -> Int {
        guard let sourceIndex, sourceIndex < index else { return index }
        return index - 1
    }
}
