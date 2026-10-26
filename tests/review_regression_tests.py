#!/usr/bin/env python3
"""Run real Swift history, session-storage and deletion-queue code in isolation.

No Chromium build or network is needed. Source fragments are extracted rather
than reimplemented, so assertions exercise the shipping implementation.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
overlay = root / 'overlay'

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    level = 1
    pos = brace + 1
    while level:
        if source[pos] == '{': level += 1
        elif source[pos] == '}': level -= 1
        pos += 1
    return source[start:pos]

browser = (overlay / 'BrowserStore.swift').read_text()
sync = (overlay / 'MillieSync.swift').read_text()
with tempfile.TemporaryDirectory(prefix='millie-regression-') as folder:
    directory = Path(folder)
    stubs = '''import SwiftUI
    enum BrowserSettings {
        static var dataDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
    }
    '''
    domain = 'millie.regression.' + __import__('uuid').uuid4().hex
    stubs += '\nlet testDomain = "' + domain + '"\nlet testDefaults = UserDefaults(suiteName: testDomain)!\n'
    helper = declaration(browser, 'enum SessionSnapshotStorage')
    queue_start = browser.index('    private(set) var pendingTabTombstones:')
    queue_end = browser.index('\n    /// A tab as it arrives', queue_start)
    queue = 'final class DeletionQueue {\n' + browser[queue_start:queue_end] + '''
        func enqueueTab(_ id: UUID) { pendingTabTombstones.insert(id) }
        func enqueueSpace(_ id: UUID) { pendingSpaceTombstones.insert(id) }
    }
    '''
    maintenance = (overlay / 'TabMaintenance.swift').read_text()
    archive_action = declaration(maintenance, 'func archiveTab(')
    archive_support = r"""
    typealias BrowserTab = TestTab
    struct TestTab: Identifiable { var id = UUID(); var profileKey: String; var urlString = "https://example.com"; var title = "Example"; var faviconURL: String? }
    struct TestContext { var pinnedTabIDs: [UUID] = [] }
    final class ArchiveStore {
        static let shared = ArchiveStore()
        var saved = 0
        func add(url: String, title: String, faviconURL: String?) { saved += 1 }
    }
    final class ArchiveHarness {
        var tabs: [TestTab] = []; var contexts: [TestContext] = []
        var closed: [UUID] = []
        func closeTab(_ id: UUID) { closed.append(id) }
    """ + archive_action + "\n}\n"
    normalize = declaration(sync, 'nonisolated static func normalizedTabURL')
    tests = r'''import Foundation
    @main struct RegressionTests {
      static func main() throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }
        let fm = FileManager.default
        let dir = BrowserSettings.dataDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name)
            print("PASS: \(name)")
        }
        let archiver = ArchiveHarness()
        let privateTab = TestTab(profileKey: "incognito")
        let ordinaryTab = TestTab(profileKey: "work")
        archiver.tabs = [privateTab, ordinaryTab]
        archiver.archiveTab(privateTab.id)
        check(ArchiveStore.shared.saved == 0 && archiver.closed.isEmpty, "private archive action cannot persist or close the tab")
        archiver.contexts = [TestContext(pinnedTabIDs: [ordinaryTab.id])]
        archiver.archiveTab(ordinaryTab.id)
        check(ArchiveStore.shared.saved == 0, "pinned tabs remain protected")
        archiver.contexts = []
        archiver.archiveTab(ordinaryTab.id)
        check(ArchiveStore.shared.saved == 1 && archiver.closed == [ordinaryTab.id], "ordinary tabs can still be archived")
        let history = HistoryStore()
        let url = "https://example.com/private-path"
        history.record(url: url, title: "Work", profileKey: "work")
        history.record(url: url, title: "Personal", profileKey: "personal")
        history.record(url: "https://example.com/secret", title: "Secret", profileKey: "incognito")
        check(history.entries.count == 2, "incognito history is never recorded")
        check(history.entries(for: "work").first?.title == "Work", "history stays in its profile")
        check(history.suggestions(for: "Work", profileKey: "personal").isEmpty, "suggestions cannot cross profiles")
        check(history.entries(for: "incognito").isEmpty, "private Spaces expose no saved history")
        history.updateTitle("Updated", for: url, profileKey: "work")
        check(history.entries(for: "personal").first?.title == "Personal", "title updates stay in profile")
        for i in 0..<2001 { history.record(url: "https://example.com/\(i)", title: "Entry", profileKey: "work") }
        check(history.entries(for: "work").count == 2000, "retention is bounded per profile")
        check(history.entries(for: "personal").count == 1, "busy profile cannot evict another profile")
        history.clear(profileKey: "work")
        check(history.entries(for: "personal").count == 1, "clear history is scoped to its profile")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let reloaded = HistoryStore()
        check(reloaded.entries(for: "personal").count == 1, "profile history survives reload")
        let legacy = """
          [{"id":"11111111-1111-1111-1111-111111111111","url":"https://legacy.example","title":"Legacy","lastVisited":0,"visitCount":1}]
          """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("history.json"))
        let migrated = HistoryStore()
        check(migrated.entries(for: "default").count == 1, "legacy history belongs only to Default")
        check(migrated.entries(for: "work").isEmpty, "legacy history does not appear in other profiles")

        struct Session: Codable, Equatable { var tabs: [String] }
        let file = dir.appendingPathComponent("session.json")
        let first = Session(tabs: ["first"]), second = Session(tabs: ["second"])
        try SessionSnapshotStorage.save(first, to: file)
        check(SessionSnapshotStorage.load(Session.self, from: file).value == first, "session round trip")
        try SessionSnapshotStorage.save(second, to: file)
        try Data("broken JSON".utf8).write(to: file)
        let recovered = SessionSnapshotStorage.load(Session.self, from: file)
        check(recovered.recovered && recovered.value == first, "corruption recovers last valid backup")
        check(recovered.preservedDamagedFile, "damaged bytes are preserved")
        try SessionSnapshotStorage.save(second, to: file)
        check(SessionSnapshotStorage.load(Session.self, from: file).value == second, "saving after recovery works")
        try fm.removeItem(at: file)
        check(SessionSnapshotStorage.load(Session.self, from: file).recovered, "missing primary recovers backup")
        try Data("also broken".utf8).write(to: file.appendingPathExtension("backup"))
        check(SessionSnapshotStorage.load(Session.self, from: file).value == nil, "unrecoverable session fails cleanly")

        let tab = UUID(), space = UUID()
        let queue = DeletionQueue()
        queue.enqueueTab(tab); queue.enqueueSpace(space)
        let restarted = DeletionQueue()
        check(restarted.pendingTabTombstones.contains(tab), "failed tab deletion survives restart")
        check(restarted.pendingSpaceTombstones.contains(space), "failed Space deletion survives restart")
        restarted.acknowledgeTabDeletion(tab)
        check(!DeletionQueue().pendingTabTombstones.contains(tab), "successful acknowledgement removes pending deletion")
        restarted.acknowledgeSpaceDeletion(space)

        check(URLNormalization.normalizedTabURL("https://EXAMPLE.COM/Path?q=ABC#top") == "https://example.com/Path?q=ABC#top", "normalization preserves case-sensitive path and query")
        check(URLNormalization.normalizedTabURL("https://example.com/path/") != URLNormalization.normalizedTabURL("https://example.com/path"), "distinct trailing-slash URLs stay distinct")
        print("All Millie regression tests passed")
      }
    }
    '''
    (directory / 'Support.swift').write_text(stubs + helper + '\n' + archive_support + queue.replace('UserDefaults.standard', 'testDefaults') + '\nenum URLNormalization {\n' + normalize + '\n}\n')
    (directory / 'Tests.swift').write_text(tests)
    executable = directory / 'tests'
    subprocess.run(['xcrun', 'swiftc', str(overlay / 'HistoryStore.swift'), str(directory / 'Support.swift'), str(directory / 'Tests.swift'), '-o', str(executable)], check=True)
    # Use a separate preferences domain too: deletion tests never touch real queues.
    subprocess.run([str(executable), str(directory / 'data')], check=True)
