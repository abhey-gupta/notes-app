import Document
@testable import Editing
import Foundation
import InkModel
import Testing

/// Automatic new pages (#172): one blank page waits at the end, without undo steps.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AutoPagesTests {
    @Test func offAddsNothing() async throws {
        let h = try Harness()
        h.pipeline.commitStroke(line(y: 100), to: h.second)
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == [h.first, h.second])
    }

    @Test func inkOnLastPageAddsBlankPageWithItsTemplate() async throws {
        let h = try Harness(pages: [Page(), Page(template: .grid(spacing: 20))])
        h.pipeline.addsPagesAutomatically = true
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 2)

        h.pipeline.commitStroke(line(y: 100), to: h.second)
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 3)
        let added = try #require(h.mirror.pageIDs.last)
        #expect(try await h.store.page(added).template == .grid(spacing: 20))
        #expect(h.pipeline.history.undoCount == 1)
        #expect(h.pipeline.history.undoActionName == "Stroke")
    }

    @Test func turningOnAfterInkedLastPageAddsOne() async throws {
        let h = try Harness(pages: [Page(), Page(strokes: [line(y: 100)])])
        h.pipeline.addsPagesAutomatically = true
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 3)
        #expect(!h.pipeline.history.canUndo)
    }

    /// Undo leaves one blank page at the end; redo brings the added page back.
    @Test func undoTrimsAddedPages() async throws {
        let h = try Harness()
        h.pipeline.addsPagesAutomatically = true
        h.pipeline.commitStroke(line(y: 100), to: h.second)
        await h.pipeline.drain()
        let third = try #require(h.mirror.pageIDs.last)
        h.pipeline.commitStroke(line(y: 100), to: third)
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 4)

        h.pipeline.undo()
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == [h.first, h.second, third])
        h.pipeline.undo()
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == [h.first, h.second])
        h.pipeline.redo()
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 3)
    }

    /// Erasing the last written page leaves the blank page that was there before.
    @Test func eraseTrimsAddedPage() async throws {
        let h = try Harness()
        h.pipeline.addsPagesAutomatically = true
        h.pipeline.commitStroke(line(y: 100), to: h.second)
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 3)
        h.pipeline.beginGesture(erasing: true)
        h.pipeline.erase([Sample(x: 50, y: 100, t: 0)], on: h.second, diameter: 16, mode: .stroke)
        h.pipeline.endGesture()
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs == [h.first, h.second])
    }

    @Test func manualPagesStay() async throws {
        let h = try Harness(pages: [Page(strokes: [line(y: 100)]), Page()])
        h.pipeline.addsPagesAutomatically = true
        h.pipeline.insertPage(after: 1, template: nil)
        h.pipeline.insertPage(after: 2, template: nil)
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 4)
    }

    @Test func closeRemovesAddedBlankPage() async throws {
        let h = try Harness()
        h.pipeline.addsPagesAutomatically = true
        h.pipeline.commitStroke(line(y: 100), to: h.second)
        await h.pipeline.drain()
        #expect(h.mirror.pageIDs.count == 3)
        h.pipeline.close()
        await h.pipeline.drain()
        #expect(await h.store.manifest.pages.map(\.id) == [h.first, h.second])
    }
}
