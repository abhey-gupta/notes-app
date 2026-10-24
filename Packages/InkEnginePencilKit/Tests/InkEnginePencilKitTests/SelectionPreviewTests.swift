import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing
import UIKit

/// Lasso chrome in the engine (#29): live path, lifted-strokes drag preview.
@MainActor
struct SelectionPreviewTests {
    @Test func lassoTouchActivatesPageAndDrawsLivePath() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .lasso))
        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 900)) // page 3
        #expect(h.engine.activePage == h.frames[2].id)
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        send(tracker.began(at(100, 900, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(200, 950, 0.01)))
        #expect(h.engine.selection.lasso.path?.boundingBoxOfPath == CGRect(x: 100, y: 900, width: 100, height: 50))
        send(tracker.ended(at(150, 990, 0.02)))
        #expect(h.engine.selection.lasso.path == nil)
    }

    /// A drag preview lifts the strokes into one image layer moved by its transform; ending it puts
    /// them back on the canvas.
    @Test func selectionPreviewLiftsStrokesAndTransformsOneLayer() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let id = RenderFixtures.strokeID(9)
        let snapshot = try #require(h.engine.snapshots[page])
        let other = RenderFixtures.line(2, from: CGPoint(x: 50, y: 300), to: CGPoint(x: 300, y: 300))
        h.engine.apply(snapshot.page.addEdit([other]), to: page)
        #expect(h.engine.canvas.drawing.strokes.count == 2)

        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [id]))
        #expect(h.engine.canvasIDs == [other.id], "lifted stroke leaves the canvas")
        #expect(h.engine.canvas.drawing.strokes.count == 1)
        #expect(!h.engine.selection.lifted.isHidden)
        #expect(h.engine.selection.lifted.contents != nil)
        let rect = h.engine.selection.rect
        #expect(rect.contains(CGPoint(x: 50, y: 50)) && rect.contains(CGPoint(x: 300, y: 50)))

        // Drag frames only move the layer: no canvas rebuilds.
        let rebuilds = h.engine.rebuildCount
        let move = CGAffineTransform(translationX: 40, y: 10)
        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [id], transform: move))
        #expect(h.engine.rebuildCount == rebuilds)
        let viewport = Viewport(contentOffset: CGPoint(x: 0, y: 900), zoomScale: 1, size: h.engine.view.bounds.size, pages: h.frames)
        let expected = CGPoint(x: rect.minX, y: rect.minY).applying(move).applying(viewport.pageToView(h.frames[1]))
        let origin = CGPoint.zero.applying(h.engine.selection.lifted.affineTransform())
        #expect(abs(origin.x - expected.x) < 1e-6 && abs(origin.y - expected.y) < 1e-6)

        // Baked edit arrives, then the preview ends: the stroke is back, moved.
        try h.engine.apply(#require(h.engine.snapshots[page]).page.transformEdit([id], by: move), to: page)
        #expect(h.engine.canvasIDs == [other.id], "still lifted until the preview ends")
        h.engine.setSelectionPreview(nil)
        #expect(h.engine.canvasIDs == [id, other.id])
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        #expect(h.engine.selection.lifted.isHidden)
        #expect(h.engine.selection.preview == nil)
    }

    /// The preview image is rendered off main when the selection is made, so a drag starts without
    /// rendering; an edit to the page makes it stale (rendered at lift instead).
    @Test func preparedImageIsUsedAtLift() async throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let id = RenderFixtures.strokeID(9)
        h.engine.prepareSelectionPreview([id], on: page)
        for _ in 0 ..< 500 where h.engine.selection.prepareTask != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.engine.selection.prepared?.image != nil)
        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [id]))
        #expect(h.engine.selection.syncRenderCount == 0)
        #expect(h.engine.selection.lifted.contents != nil)
        h.engine.setSelectionPreview(nil)

        let snapshot = try #require(h.engine.snapshots[page])
        try h.engine.apply(snapshot.page.recolorEdit([id], to: .semantic(.red)), to: page)
        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [id]))
        #expect(h.engine.selection.syncRenderCount == 1, "stale after the edit")
        h.engine.prepareSelectionPreview([], on: page)
        #expect(h.engine.selection.prepared == nil)
    }
}
