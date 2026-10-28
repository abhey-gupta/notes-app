import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing

/// The canvas pool (ARCHITECTURE.md §3): visible pages share a few `PKCanvasView`s; a page without one shows
/// its raster; a canvas never carries ink or an in-progress stroke from one page to another.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct CanvasPoolTests {
    @Test func pageKeepsItsWholeRasterUntilTheCanvasHasDrawnIt() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page2 = try #require(h.engine.pageViews[h.frames[1].id])
        let page3 = try #require(h.engine.pageViews[h.frames[2].id])
        #expect(page2.inkHole == nil && page3.inkHole == nil)
        #expect(!page2.inkLayer.isHidden)

        try h.engine.canvasViewDidFinishRendering(#require(h.canvas(1)).view)
        #expect(page2.inkHole == CGRect(x: 0, y: 34, width: 595, height: 808), "raster leaves the canvas's region to it")
        #expect(page3.inkHole == nil)
        try h.engine.canvasViewDidFinishRendering(#require(h.canvas(2)).view)
        #expect(page3.inkHole == CGRect(x: 0, y: 0, width: 595, height: 534))
        // Scrolling moves the hole with the canvas.
        h.scroll(toY: 1000)
        #expect(page2.inkHole == CGRect(x: 0, y: 134, width: 595, height: 708))
    }

    /// Every page but the first draws a one-pixel seam along its top edge, over its image (#162).
    @Test func pagesBelowTheFirstDrawAHairlineSeam() throws {
        let h = Harness()
        h.scroll(toY: 0)
        let page1 = try #require(h.engine.pageViews[h.frames[0].id])
        #expect(page1.seamLayer.isHidden)
        h.scroll(toY: 900)
        let page2 = try #require(h.engine.pageViews[h.frames[1].id])
        #expect(!page2.seamLayer.isHidden)
        #expect(page2.seamLayer.frame.minY == 0 && page2.seamLayer.frame.width == 595)
        #expect(page2.seamLayer.frame.height > 0 && page2.seamLayer.frame.height <= 1)
        #expect(page2.layer.sublayers?.last === page2.seamLayer)
    }

    /// With the pool exhausted, a visible page without a canvas shows its raster, pending strokes included.
    @Test func pendingStrokesAreInTheRasterOfAPageThatLostItsCanvas() throws {
        let h = Harness()
        h.engine.maximumCanvases = 1
        h.scroll(toY: 900) // center at content y 1583: page 2 gets the one canvas
        #expect(h.canvas(1) != nil && h.canvas(2) == nil)
        h.userDraws(RenderFixtures.line(1, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 200, y: 120)))
        h.scroll(toY: 1400) // center at 2083: page 3 takes the canvas before the document echoed the stroke
        #expect(h.canvas(2) != nil && h.canvas(1) == nil)
        let key = try #require(h.engine.pageViews[h.frames[1].id]?.requestedKey)
        #expect(key.strokeCount == 1)
        #expect(key.pendingCount == 1)
    }

    @Test func pagesLeavingTheViewportAreDropped() {
        let h = Harness()
        h.scroll(toY: 0)
        #expect(h.engine.pagesView.subviews.count == 3)
        #expect(h.engine.canvases.filter { $0.page != nil }.count == 2, "pages 1 and 2 are on screen")
        h.engine.setViewport(Viewport(contentOffset: CGPoint(x: 0, y: 1800), zoomScale: 1, size: h.viewSize, pages: [h.frames[2]]))
        #expect(h.engine.pagesView.subviews.count == 1)
        #expect(h.engine.canvases.filter { $0.page != nil }.map(\.page) == [h.frames[2].id])
        #expect(h.engine.canvases.count == 2, "freed canvases stay pooled")
    }

    /// A freed canvas holds no ink, so handing it to another page can't show the old page's strokes there
    /// (the one-canvas design's ghost ink after a pinch); the page it left keeps its own strokes.
    @Test func freedCanvasCarriesNoInkToItsNextPage() throws {
        let h = Harness()
        h.engine.maximumCanvases = 1
        h.scroll(toY: 900) // page 2 (one stroke) gets the canvas
        let canvas = try #require(h.canvas(1))
        #expect(canvas.view.drawing.strokes.count == 1)
        h.scroll(toY: 1400) // page 3 (blank) takes it
        #expect(h.canvas(2) === canvas)
        #expect(canvas.view.drawing.strokes.isEmpty && canvas.ids.isEmpty)
        h.scroll(toY: 900)
        #expect(h.canvas(1) === canvas)
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        #expect(h.engine.snapshots[h.frames[1].id]?.strokes.count == 1)
        #expect(h.engine.snapshots[h.frames[2].id]?.strokes.isEmpty == true)
        #expect(h.recorder.commits.isEmpty, "no stroke was invented by moving the canvas")
    }

    /// Scrolling (or pinching) a page away mid-stroke doesn't move its canvas: the stroke commits to the page
    /// it began on, never to whichever page is under the viewport when it ends.
    @Test func strokeInProgressCommitsToThePageItBeganOn() throws {
        let h = Harness()
        h.engine.maximumCanvases = 1
        h.scroll(toY: 900)
        let canvas = try #require(h.canvas(1))
        h.engine.canvasViewDidBeginUsingTool(canvas.view)
        h.engine.setViewport(Viewport(contentOffset: CGPoint(x: 0, y: 1800), zoomScale: 1, size: h.viewSize, pages: [h.frames[2]]))
        #expect(h.canvas(1) === canvas, "kept by its page")
        #expect(h.canvas(2) == nil)
        #expect(!canvas.view.isHidden)
        h.userDraws(RenderFixtures.line(1, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 200, y: 120)))
        h.engine.canvasViewDidEndUsingTool(canvas.view)
        #expect(h.recorder.commits.map(\.1) == [h.frames[1].id])
        h.scroll(toY: 1800) // at rest again: page 3 can have the canvas now
        #expect(h.canvas(2) === canvas)
        #expect(h.canvas(1) == nil)
    }
}
