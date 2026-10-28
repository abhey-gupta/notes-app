import CoreGraphics
import Document
@testable import Editing
import Foundation
import InkModel
import Testing
import Tools

/// In-memory `PageMirror`: the store's pages as the pipeline last told it about them.
@MainActor
final class RecordingMirror: PageMirror {
    let store: DocumentStore
    private(set) var pageIDs: [PageID]
    private(set) var pages: [PageID: Page] = [:]
    private(set) var reloads: [PageID] = []
    private(set) var pageChanges = 0

    init(store: DocumentStore, pageIDs: [PageID]) {
        self.store = store
        self.pageIDs = pageIDs
    }

    func page(_ id: PageID) -> Page? {
        pages[id]
    }

    func ensureLoaded(_ id: PageID) async throws(DocumentError) -> Page {
        if let page = pages[id] {
            return page
        }
        let page = try await store.page(id)
        pages[id] = page
        return page
    }

    func didApply(_ edit: PageEdit, to page: PageID) {
        _ = try? pages[page]?.apply(edit)
    }

    func reload(_ page: PageID) async {
        reloads.append(page)
        pages[page] = try? await store.page(page)
    }

    func pagesDidChange() async {
        pageChanges += 1
        pageIDs = await store.manifest.pages.map(\.id)
        pages = pages.filter { pageIDs.contains($0.key) }
    }
}

/// A two-page notebook in a temp dir with a real store, mirror and pipeline.
@MainActor
final class Harness {
    let dir: URL
    let store: DocumentStore
    let mirror: RecordingMirror
    let pipeline: EditPipeline
    let undoManager: UndoManager?
    let first: PageID
    let second: PageID

    init(pages: [Page] = [Page(), Page()], undoManager: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "EditingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notebook = Notebook(title: "Test", pages: pages.map(\.id))
        let package = try NotebookPackage.create(at: dir.appending(path: "n.nb"), notebook: notebook, pages: pages)
        store = DocumentStore(package: package, options: .init(idleDelay: nil))
        mirror = RecordingMirror(store: store, pageIDs: pages.map(\.id))
        if undoManager {
            let manager = UndoManager()
            manager.groupsByEvent = false
            self.undoManager = manager
        } else {
            self.undoManager = nil
        }
        pipeline = EditPipeline(store: store, mirror: mirror, undoManager: self.undoManager)
        first = pages[0].id
        second = pages[1].id
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func strokes(_ page: PageID) async throws -> [StrokeID] {
        try await store.page(page).strokes.map(\.id)
    }
}

func line(y: Float, from x0: Float = 20, to x1: Float = 300) -> Stroke {
    Stroke(
        tool: .ballpoint, color: .primary, width: 2,
        samples: stride(from: x0, through: x1, by: 2).map { Sample(x: $0, y: y, force: 0.5, t: $0 / 240) }
    )
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EditPipelineTests {
    @Test func strokeReachesStoreMirrorAndHistory() async throws {
        let h = try Harness()
        let stroke = line(y: 100)
        h.pipeline.commitStroke(stroke, to: h.first)
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first) == [stroke.id])
        #expect(h.mirror.page(h.first)?.strokes.map(\.id) == [stroke.id])
        #expect(h.pipeline.history.undoActionName == "Stroke")
        #expect(h.undoManager?.undoActionName == "Stroke")
    }

    /// The bug this module exists for: undo tapped while a stroke is still being saved takes back that
    /// stroke, not the one before it, and keeps it redoable.
    @Test(arguments: [true, false])
    func undoWaitsForQueuedStroke(withUndoManager: Bool) async throws {
        let h = try Harness(undoManager: withUndoManager)
        let (a, b) = (line(y: 100), line(y: 200))
        h.pipeline.commitStroke(a, to: h.first)
        await h.pipeline.drain()
        h.pipeline.commitStroke(b, to: h.first)
        h.pipeline.undo() // before `b` has reached the history
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first) == [a.id])
        #expect(h.pipeline.history.canRedo)
        h.pipeline.redo()
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first) == [a.id, b.id])
    }

    /// ⌘Z / three-finger undo goes straight to the undo manager; the stack still moves in order.
    @Test func systemUndoWaitsForQueuedStroke() async throws {
        let h = try Harness()
        let manager = try #require(h.undoManager)
        let (a, b) = (line(y: 100), line(y: 200))
        h.pipeline.commitStroke(a, to: h.first)
        await h.pipeline.drain()
        h.pipeline.commitStroke(b, to: h.first)
        manager.undo()
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first) == [a.id])
    }

    /// A scrub across both pages in many batches is one undo step; undo restores both pages.
    @Test func eraserGestureIsOneUndoStep() async throws {
        let (top, bottom) = (line(y: 100), line(y: 100))
        let h = try Harness(pages: [Page(strokes: [top]), Page(strokes: [bottom])])
        h.pipeline.beginGesture(erasing: true)
        for page in [h.first, h.second] {
            for x in stride(from: Float(0), through: 320, by: 10) {
                h.pipeline.erase([Sample(x: x, y: 100, t: 0)], on: page, diameter: 16, mode: .partial)
            }
        }
        h.pipeline.endGesture()
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first).isEmpty)
        #expect(try await h.strokes(h.second).isEmpty)
        #expect(h.pipeline.history.undoCount == 1)
        #expect(h.pipeline.history.undoActionName == "Erase")

        h.pipeline.undo()
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first) == [top.id])
        #expect(try await h.strokes(h.second) == [bottom.id])
        #expect(h.mirror.page(h.second)?.strokes.map(\.id) == [bottom.id])
    }

    /// A pen stroke after an eraser gesture (no lift in between) closes the erase step first.
    @Test func newGestureClosesTheEraseStep() async throws {
        let h = try Harness(pages: [Page(strokes: [line(y: 100)]), Page()])
        h.pipeline.beginGesture(erasing: true)
        h.pipeline.erase([Sample(x: 50, y: 100, t: 0)], on: h.first, diameter: 16, mode: .stroke)
        h.pipeline.beginGesture(erasing: false)
        h.pipeline.commitStroke(line(y: 300), to: h.first)
        await h.pipeline.drain()
        #expect(h.pipeline.history.undoCount == 2)
        #expect(h.pipeline.history.undoActionName == "Stroke")
    }

    @Test func editHandsBackResultAndEditedPage() async throws {
        let stroke = line(y: 100)
        let h = try Harness(pages: [Page(strokes: [stroke]), Page()])
        var seen: (String?, Page?) = (nil, nil)
        h.pipeline.edit("Recolor", on: h.first, make: { page in
            try ([page.recolorEdit([stroke.id], to: .custom(RGBA8(rgba: 0xFF00_00FF)))], "done")
        }, then: { seen = ($0, $1) })
        await h.pipeline.drain()
        #expect(seen.0 == "done")
        #expect(seen.1?.strokes.first?.color == .custom(RGBA8(rgba: 0xFF00_00FF)))
        #expect(h.pipeline.history.undoActionName == "Recolor")

        var ran = false
        h.pipeline.edit("Nothing", on: h.first, make: { _ -> ([PageEdit], Int)? in nil }, then: { result, page in
            ran = result == nil && page == nil
        })
        await h.pipeline.drain()
        #expect(ran)
        #expect(h.pipeline.history.undoCount == 1)
    }

    /// The store refuses an edit built against a stale page: nothing is recorded, the mirror re-reads it.
    @Test func refusedEditReloadsThePage() async throws {
        let stroke = line(y: 100)
        let h = try Harness(pages: [Page(strokes: [stroke]), Page()])
        var page: Page?
        h.pipeline.read(h.first) { page = $0 }
        await h.pipeline.drain()
        let stale = try #require(page)
        h.pipeline.edit("Delete", on: h.first, make: { try ([$0.removeEdit([stroke.id])], ()) })
        h.pipeline.edit("Delete again", on: h.first, make: { _ in try ([stale.removeEdit([stroke.id])], ()) })
        await h.pipeline.drain()
        #expect(h.mirror.reloads == [h.first])
        #expect(h.pipeline.history.undoCount == 1)
        #expect(h.pipeline.history.undoActionName == "Delete")
    }

    @Test func deletedPagesComeBackWithTheirInk() async throws {
        let stroke = line(y: 100)
        let h = try Harness(pages: [Page(), Page(strokes: [stroke]), Page()])
        let order = h.mirror.pageIDs
        h.pipeline.deletePages([h.second])
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == [order[0], order[2]])
        #expect(h.pipeline.history.undoActionName == "Delete Page")

        h.pipeline.undo()
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == order)
        #expect(try await h.strokes(h.second) == [stroke.id])
    }

    @Test func neverDeletesEveryPage() async throws {
        let h = try Harness()
        h.pipeline.deletePages([h.first, h.second])
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 2)
        #expect(!h.pipeline.history.canUndo)
    }

    @Test func insertAndMoveAreUndoable() async throws {
        let h = try Harness()
        var inserted: Int?
        h.pipeline.insertPage(after: 0, template: .blank) { inserted = $0 }
        h.pipeline.movePage(from: 0, to: 2)
        await h.pipeline.drain()
        #expect(inserted == 1)
        #expect(h.mirror.pageIDs.count == 3)
        #expect(h.mirror.pageIDs.last == h.first)

        h.pipeline.undo()
        h.pipeline.undo()
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == [h.first, h.second])
    }

    @Test func historyCallbacksBracketUndo() async throws {
        let h = try Harness()
        var events: [String] = []
        h.pipeline.onHistoryWillApply = { events.append("will") }
        h.pipeline.onHistoryApplied = { events.append("did \($0.count)") }
        h.pipeline.onPageEdited = { _ in events.append("edited") }
        h.pipeline.commitStroke(line(y: 100), to: h.first)
        h.pipeline.undo()
        await h.pipeline.drain()
        #expect(events == ["edited", "will", "edited", "did 1"])
    }

    @Test func closeForgetsHistoryButFinishesQueuedEdits() async throws {
        let h = try Harness()
        let stroke = line(y: 100)
        h.pipeline.commitStroke(stroke, to: h.first)
        h.pipeline.close()
        await h.pipeline.drain()
        #expect(try await h.strokes(h.first) == [stroke.id])
        #expect(h.undoManager?.canUndo == false)
    }
}
