@testable import Canvas
import CoreGraphics
import Document
import Foundation
import InkModel
import Testing

/// `PageSink` that keeps what residency handed it.
@MainActor
final class RecordingSink: PageSink {
    private(set) var pushes: [[PageSnapshot]] = []
    private(set) var applied: [(PageEdit, PageID)] = []
    /// Pages handed to ``prepare(_:)``, each with whether the sink already held its strokes then.
    private(set) var prepared: [(id: PageID, wasShown: Bool)] = []

    var shown: [PageSnapshot] {
        pushes.last ?? []
    }

    func setPages(_ pages: [PageSnapshot]) {
        pushes.append(pages)
    }

    func apply(_ edit: PageEdit, to page: PageID) {
        applied.append((edit, page))
    }

    func prepare(_ page: PageSnapshot) async {
        prepared.append((page.id, shown.contains { $0.id == page.id && $0.isLoaded }))
    }
}

/// A notebook of `count` one-stroke pages in a temp dir, with a real store and a recording sink.
@MainActor
final class ResidencyHarness {
    let dir: URL
    let store: DocumentStore
    let sink = RecordingSink()
    let residency: PageResidency
    let ids: [PageID]
    private(set) var loaded: [PageID] = []
    private(set) var evicted: [PageID] = []

    init(count: Int = 12) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "ResidencyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pages = (0 ..< count).map { i in Page(strokes: [dot(y: Float(i))]) }
        let package = try NotebookPackage.create(
            at: dir.appending(path: "n.nb"),
            notebook: Notebook(title: "T", pages: pages.map(\.id)),
            pages: pages
        )
        store = DocumentStore(package: package, options: .init(idleDelay: nil))
        ids = pages.map(\.id)
        residency = PageResidency(store: store, sink: sink, pageSize: Notebook.a4Portrait, pages: pages.map { ($0.id, $0.template) })
        residency.onPageLoaded = { [weak self] in self?.loaded.append($0) }
        residency.onPageEvicted = { [weak self] in self?.evicted.append($0) }
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func show(_ visible: Range<Int>) {
        residency.update(PageWindow(visible: visible, pageCount: ids.count))
    }

    /// Waits (≤ 5 s) until `condition` holds.
    func until(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }

    /// Every resident page (visible ± 3) is in the mirror.
    func settle() async throws {
        let window = try #require(residency.window)
        try await until { window.resident.allSatisfy { residency.page(ids[$0]) != nil } }
    }
}

func dot(y: Float) -> Stroke {
    Stroke(tool: .ballpoint, color: .primary, width: 2, samples: [Sample(x: 10, y: 10 + y, t: 0), Sample(x: 12, y: 10 + y, t: 0.01)])
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PageResidencyTests {
    /// Open: the engine gets paper for the engine window at once, ink as pages arrive, page 1 first.
    @Test func showsPlaceholdersThenLoadsVisiblePageFirst() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        #expect(h.sink.shown.map(\.id) == [h.ids[0], h.ids[1]])
        #expect(h.sink.shown.allSatisfy { !$0.isLoaded })

        try await h.settle()
        #expect(h.loaded.first == h.ids[0])
        #expect(Set(h.loaded) == Set(h.ids[0 ... 3]))
        #expect(h.sink.shown.allSatisfy { $0.isLoaded && $0.strokes.count == 1 })
    }

    /// Loaded pages bound for the engine are prepared (off main) before the engine gets their strokes;
    /// pages only kept resident aren't.
    @Test func preparesEnginePagesBeforeHandingThemOver() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        #expect(Set(h.sink.prepared.map(\.id)) == [h.ids[0], h.ids[1]])
        #expect(h.sink.prepared.allSatisfy { !$0.wasShown })
    }

    @Test func scrollingAwayReleasesPages() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        h.show(9 ..< 10)
        #expect(h.residency.page(h.ids[0]) == nil)
        #expect(h.evicted.contains(h.ids[0]))
        #expect(h.sink.shown.map(\.id) == [h.ids[8], h.ids[9], h.ids[10]])
        try await h.settle()
        try await h.until { await !h.store.isLoaded(h.ids[0]) }
    }

    /// An accepted edit updates the mirror and reaches the engine as an edit, not a new snapshot.
    @Test func acceptedEditIsEchoedWithoutResnapshot() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        let pushes = h.sink.pushes.count
        let edit = try await h.residency.ensureLoaded(h.ids[0]).addEdit([dot(y: 50)])
        _ = try await h.store.apply(edit, to: h.ids[0])
        h.residency.didApply(edit, to: h.ids[0])
        #expect(h.residency.page(h.ids[0])?.strokes.count == 2)
        #expect(h.sink.applied.map(\.1) == [h.ids[0]])
        h.show(0 ..< 1)
        #expect(h.sink.pushes.count == pushes)
    }

    /// An edit accepted while its page loads isn't lost: the load may predate it, so the page is read again
    /// (a second view's residency in split view, #175, gets edits for pages it's still loading).
    @Test func editDuringLoadSurvives() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        let page = try await h.store.page(h.ids[0])
        let edit = try page.addEdit([dot(y: 50)])
        _ = try await h.store.apply(edit, to: h.ids[0])
        h.residency.didApply(edit, to: h.ids[0])
        try await h.settle()
        try await h.until { h.residency.page(h.ids[0])?.strokes.count == 2 }
    }

    /// A second view of the notebook (#175) leaves the store's memory alone when pages scroll away.
    @Test func followerKeepsStorePages() async throws {
        let h = try ResidencyHarness()
        h.residency.evictsFromStore = false
        h.show(0 ..< 1)
        try await h.settle()
        h.show(9 ..< 10)
        try await h.settle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.residency.page(h.ids[0]) == nil, "out of the mirror")
        #expect(await h.store.isLoaded(h.ids[0]), "still in the store")
    }

    /// After a refused edit the page leaves the engine (dropping ink it drew) and comes back as saved.
    @Test func reloadRebuildsThePageFromTheStore() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        let pushes = h.sink.pushes.count
        await h.residency.reload(h.ids[0])
        #expect(h.sink.pushes[pushes].map(\.id) == [h.ids[1]])
        #expect(h.sink.shown.map(\.id) == [h.ids[0], h.ids[1]])
        #expect(h.sink.shown.first?.strokes.count == 1)
    }

    /// Reading a page far from the screen (thumbnails, "has ink?") doesn't keep it in memory.
    @Test func peekReleasesPagesOutsideTheWindow() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        let page = try await h.residency.peek(h.ids[10])
        #expect(page.strokes.count == 1)
        #expect(h.residency.page(h.ids[10]) == nil)
        try await h.until { await !h.store.isLoaded(h.ids[10]) }
    }

    /// A peek while the window is still loading never releases a page the window keeps.
    @Test func peekKeepsPagesTheWindowWants() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        for id in h.ids[0 ... 3] {
            _ = try await h.residency.peek(id)
        }
        try await h.settle()
        try await Task.sleep(for: .milliseconds(50)) // let any release run
        for id in h.ids[0 ... 3] {
            #expect(h.residency.page(id) != nil)
            #expect(await h.store.isLoaded(id))
        }
    }

    @Test func visibilityFollowsWindowAndPageOrder() throws {
        let h = try ResidencyHarness()
        #expect(!h.residency.isVisible(h.ids[0]))
        h.show(2 ..< 4)
        #expect(h.residency.isVisible(h.ids[2]))
        #expect(h.residency.isVisible(h.ids[3]))
        #expect(!h.residency.isVisible(h.ids[4]))

        // Page 2 moves to the end: no longer on screen once the host reports the new window.
        var order = h.ids
        order.append(order.remove(at: 2))
        h.residency.setPages(order.map { ($0, PageTemplate.blank) })
        #expect(!h.residency.isVisible(h.ids[2]))
        h.residency.update(PageWindow(visible: 2 ..< 4, pageCount: order.count))
        #expect(!h.residency.isVisible(h.ids[2]))
        #expect(h.residency.isVisible(h.ids[3]))
    }

    @Test func deletedPagesLeaveTheMirror() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        h.residency.setPages(h.ids.dropFirst().map { ($0, PageTemplate.blank) })
        #expect(h.residency.page(h.ids[0]) == nil)
        #expect(h.residency.pageIDs == Array(h.ids.dropFirst()))
    }

    @Test func templateChangeReachesTheEngine() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        try await h.settle()
        let grid = PageTemplate.grid(spacing: 20)
        h.residency.setTemplate(grid, for: h.ids)
        #expect(h.sink.shown.allSatisfy { $0.page.template == grid })
        #expect(h.residency.page(h.ids[3])?.template == grid)
    }

    @Test func closeStopsLoading() async throws {
        let h = try ResidencyHarness()
        h.show(0 ..< 1)
        h.residency.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.loaded.isEmpty)
        #expect(h.residency.page(h.ids[0]) == nil)
        h.show(5 ..< 6)
        #expect(h.sink.pushes.count == 1)
    }
}
