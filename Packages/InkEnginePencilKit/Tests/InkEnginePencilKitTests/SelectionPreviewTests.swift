import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing
import UIKit

/// Lasso chrome in the engine (#29): live path, lifted-strokes drag preview.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct SelectionPreviewTests {
    @Test func lassoDrawsItsLivePathInContentSpace() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .lasso))
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        // Content (100, 1800): page 3 (content y 1732...), page point (100, 68).
        send(tracker.began(at(100, 1800, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(200, 1850, 0.01)))
        #expect(h.engine.selection.lasso.path?.boundingBoxOfPath == CGRect(x: 100, y: 1800, width: 100, height: 50))
        send(tracker.ended(at(150, 1890, 0.02)))
        #expect(h.engine.selection.lasso.path == nil)
        #expect(h.recorder.lassos.first?.1 == h.frames[2].id)
        #expect(h.recorder.lassos.first?.0.first == CGPoint(x: 100, y: 68))
    }

    /// The lasso layer zooms with the page, so its dash is scaled back to stay 1.5 pt on screen.
    @Test func lassoDashStaysScreenSizedAtAnyZoom() {
        let h = Harness()
        h.engine.setTool(ToolConfiguration(tool: .lasso))
        for zoom in [0.5, 2] as [CGFloat] {
            h.scroll(toY: 0, zoom: zoom)
            var tracker = InkInputTracker()
            let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
            for event in tracker.began(at(100, 100, 0), target: { h.engine.inkInputView(h.engine.input, targetAt: $0) }) {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
            #expect(h.engine.selection.lasso.lineWidth == 1.5 / zoom)
            let dash = h.engine.selection.lasso.lineDashPattern?.map { CGFloat($0.doubleValue) } ?? []
            #expect(dash.count == 2 && abs(dash[0] - 5 / zoom) < 1e-3 && abs(dash[1] - 4 / zoom) < 1e-3, "\(dash)")
            for event in tracker.ended(at(100, 100, 0.1)) {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
    }

    /// A drag preview lifts the strokes into one image layer moved by its transform; ending it puts
    /// them back on the page's canvas.
    @Test func selectionPreviewLiftsStrokesAndTransformsOneLayer() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1]
        let id = RenderFixtures.strokeID(9)
        let snapshot = try #require(h.engine.snapshots[page.id])
        let other = RenderFixtures.line(2, from: CGPoint(x: 50, y: 300), to: CGPoint(x: 300, y: 300))
        h.engine.apply(snapshot.page.addEdit([other]), to: page.id)
        let canvas = try #require(h.engine.canvas(for: page.id))
        #expect(canvas.view.drawing.strokes.count == 2)

        h.engine.setSelectionPreview(SelectionPreview(page: page.id, strokes: [id]))
        #expect(canvas.ids == [other.id], "lifted stroke leaves the canvas")
        #expect(canvas.view.drawing.strokes.count == 1)
        #expect(!h.engine.selection.lifted.isHidden)
        #expect(h.engine.selection.lifted.contents != nil)
        let rect = h.engine.selection.rect
        #expect(rect.contains(CGPoint(x: 50, y: 50)) && rect.contains(CGPoint(x: 300, y: 50)))

        // Drag frames only move the layer: no canvas rebuilds.
        let rebuilds = h.engine.rebuildCount
        let move = CGAffineTransform(translationX: 40, y: 10)
        h.engine.setSelectionPreview(SelectionPreview(page: page.id, strokes: [id], transform: move))
        #expect(h.engine.rebuildCount == rebuilds)
        let expected = CGPoint(x: rect.minX, y: rect.minY).applying(move).applying(CGAffineTransform(translationX: 0, y: page.frame.minY))
        let origin = CGPoint.zero.applying(h.engine.selection.lifted.affineTransform())
        #expect(abs(origin.x - expected.x) < 1e-6 && abs(origin.y - expected.y) < 1e-6)

        // Baked edit arrives, then the preview ends: the stroke is back, moved.
        try h.engine.apply(#require(h.engine.snapshots[page.id]).page.transformEdit([id], by: move), to: page.id)
        #expect(canvas.ids == [other.id], "still lifted until the preview ends")
        h.engine.setSelectionPreview(nil)
        #expect(canvas.ids == [id, other.id])
        h.engine.canvasViewDidFinishRendering(canvas.view)
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
