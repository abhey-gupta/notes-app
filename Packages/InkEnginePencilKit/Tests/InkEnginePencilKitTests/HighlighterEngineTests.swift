import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkGeometry
import InkModel
import PencilKit
import Testing
import UIKit

/// The highlighter on the engine (#120): drawn live and committed through the input view as shape layers
/// in its page view, never on a PencilKit canvas; lifted and put back; recolored with the theme.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct HighlighterEngineTests {
    typealias Fixtures = HighlighterFixtures

    @Test func highlighterTakesTheInputViewNotACanvas() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Fixtures.tool)
        #expect(!h.engine.input.isHidden)
        #expect(h.engine.canvases.allSatisfy { !$0.view.isUserInteractionEnabled })
        #expect(h.engine.usesHighlighter && !h.engine.usesFlatPen)
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint)))
        #expect(h.engine.input.isHidden)
        #expect(!h.engine.usesHighlighter)
    }

    @Test func canvasesNeverHoldHighlights() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let canvas = try #require(h.canvas(1))
        let rebuilds = h.engine.rebuildCount
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([Fixtures.highlight]), to: page)
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        #expect(canvas.view.drawing.strokes.count == 1)
        #expect(h.engine.rebuildCount == rebuilds, "nothing on the canvas changed")
        let view = try #require(h.engine.pageViews[page])
        let layers = view.highlightShapeLayers
        #expect(layers.count == 1)
        #expect(layers.first.map { abs(($0.path?.boundingBox.height ?? 0) + $0.lineWidth - 24) < 0.01 } == true)
        #expect(layers.first?.fillColor != nil && layers.first?.strokeColor == layers.first?.fillColor)
        #expect(layers.first?.lineJoin == .round)
        #expect(layers.first?.frame.contains(CGPoint(x: 250, y: 100)) == true)
        #expect(layers.first?.opacity == Float(Highlight.opacity))
        h.engine.rebuildCanvas(canvas)
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        #expect(view.highlightShapeLayers.first === layers.first, "a rebuild keeps the layer")
    }

    @Test func strokeIsDrawnLiveBeneathInkAndCommitted() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Fixtures.tool)
        let page = h.frames[2].id
        let canvas = try #require(h.canvas(2))
        let view = try #require(h.engine.pageViews[page])
        let rebuilds = h.engine.rebuildCount

        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in
            TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t, force: 1, altitude: 0.8)
        }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        send(tracker.began(at(100, 1800, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(200, 1800, 0.01), coalesced: [at(150, 1800, 0.005), at(200, 1800, 0.01)]))
        // Live: a band in the page view, under the ink raster and canvas; nothing on the canvas.
        let live = try #require(h.engine.selection.liveHighlight)
        #expect(live.page == page)
        #expect(view.highlightShapeLayers == [live.layer])
        #expect(live.layer.path != nil)
        #expect(abs((live.layer.path?.boundingBox.height ?? 0) + live.layer.lineWidth - 16) < 0.01)
        #expect(live.layer.frame.contains(CGPoint(x: 150, y: 1800 - h.frames[2].frame.minY)))
        #expect(canvas.view.drawing.strokes.isEmpty)
        send(tracker.ended(at(300, 1800, 0.02)))
        #expect(h.engine.selection.liveHighlight == nil)

        let (stroke, committedTo) = try #require(h.recorder.commits.first)
        #expect(committedTo == page)
        #expect(stroke.id == live.template.id)
        #expect(stroke.tool == .highlighter)
        #expect(stroke.color == .semantic(.red))
        #expect(stroke.width == 16)
        #expect(stroke.samples.count == 4)
        #expect(stroke.samples.first.map { CGFloat($0.y) } == 1800 - h.frames[2].frame.minY)
        let rendering = try #require(stroke.rendering)
        #expect(rendering.ink == StrokeRendering.Ink.highlighter)
        #expect(rendering.points.allSatisfy { $0.width == 16 && $0.height == 16 })
        #expect(Highlight.width(of: stroke) == 16)

        // The live layer is now the stroke's; pending until the document echoes it; the canvas untouched.
        #expect(view.highlightShapeLayers == [live.layer])
        #expect(h.engine.pending[page]?.count == 1)
        #expect(canvas.ids.isEmpty && canvas.view.drawing.strokes.isEmpty)
        #expect(h.engine.rebuildCount == rebuilds)
        let snapshot = try #require(h.engine.snapshots[page])
        h.engine.apply(snapshot.page.addEdit([stroke]), to: page)
        #expect(h.engine.pending[page]?.isEmpty ?? true)
        #expect(h.engine.rebuildCount == rebuilds)
        #expect(view.highlightShapeLayers == [live.layer], "the echo keeps the layer")
        #expect(h.engine.snapshots[page]?.strokes.count == 1)
    }

    /// The round nib (#215): the tool's nib is the committed stroke's ink, and its band has round ends.
    @Test func roundNibStrokeCarriesItsInk() throws {
        let h = Harness()
        h.scroll(toY: 900)
        var tool = Fixtures.tool
        tool.highlighterNib = .round
        h.engine.setTool(tool)
        let page = h.frames[2].id
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, t: Double) in
            TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: 1800), timestamp: t, force: 1, altitude: 0.8)
        }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        send(tracker.began(at(100, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(200, 0.01), coalesced: [at(150, 0.005), at(200, 0.01)]))
        let live = try #require(h.engine.selection.liveHighlight)
        #expect(live.template.rendering?.highlighterNib == .round)
        send(tracker.ended(at(300, 0.02)))
        let (stroke, committedTo) = try #require(h.recorder.commits.first)
        #expect(committedTo == page)
        #expect(stroke.rendering?.ink == StrokeRendering.Ink.roundHighlighter)
        #expect(Highlight.width(of: stroke) == 16)
        let band = try #require(live.layer.path?.boundingBox)
        #expect(abs(band.width + live.layer.lineWidth - 216) < 0.5, "round ends reach half the height past the ends")

        let chisel = Highlight.stroke(color: .primary, width: 16, samples: stroke.samples)
        #expect(chisel.rendering?.ink == StrokeRendering.Ink.highlighter)
        #expect(Highlight.stroke(stroke, samples: chisel.samples).rendering?.highlighterNib == .round, "the template keeps its nib")
    }

    /// Bands multiply with the page (#196) on light paper and over artwork; night paper alone keeps the
    /// plain band.
    @Test func bandsMultiplyOnLightPaperAndOverArtwork() throws {
        let h = Harness()
        let (plain, pdf) = (h.frames[1].id, h.frames[2].id)
        h.engine.pageArtwork = { $0 == pdf ? CountingArtwork() : nil }
        h.scroll(toY: 900)
        for page in [plain, pdf] {
            try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([Fixtures.highlight]), to: page)
        }
        let filter = { (page: PageID) in h.engine.pageViews[page]?.highlightsFilter }
        #expect(filter(plain) == Highlight.multiplyFilter)
        #expect(filter(pdf) == Highlight.multiplyFilter)
        h.engine.setTheme(.night)
        #expect(filter(plain) == nil)
        #expect(filter(pdf) == Highlight.multiplyFilter)
    }

    @Test func erasingAHighlightTakesItsLayerAway() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([Fixtures.highlight]), to: page)
        let view = try #require(h.engine.pageViews[page])
        #expect(view.highlightShapeLayers.count == 1)
        try h.engine.apply(#require(h.engine.snapshots[page]).page.removeEdit([Fixtures.highlight.id]), to: page)
        #expect(view.highlightShapeLayers.isEmpty)
    }

    @Test func cancelledStrokeLeavesNothing() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Fixtures.tool)
        let view = try #require(h.engine.pageViews[h.frames[2].id])
        var tracker = InkInputTracker()
        let touch = TouchRecord(id: TouchID(1), location: CGPoint(x: 100, y: 1800), timestamp: 0)
        for event in tracker.began(touch, target: { h.engine.inkInputView(h.engine.input, targetAt: $0) }) {
            h.engine.inkInputView(h.engine.input, didProduce: event)
        }
        #expect(view.highlightShapeLayers.count == 1)
        for event in tracker.cancelled(touch) {
            h.engine.inkInputView(h.engine.input, didProduce: event)
        }
        #expect(view.highlightShapeLayers.isEmpty)
        #expect(h.recorder.commits.isEmpty)
    }

    @Test func liftedHighlightLeavesTheViewAndComesBackMoved() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let mark = RenderFixtures.line(2, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 320, y: 50), tool: .highlighter, width: 16)
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([mark]), to: page)
        let view = try #require(h.engine.pageViews[page])
        let canvas = try #require(h.canvas(1))
        let before = try #require(view.highlightShapeLayers.first?.frame)
        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [mark.id]))
        #expect(view.highlightShapeLayers.isEmpty, "the lifted image shows it")
        #expect(h.engine.selection.lifted.contents != nil)
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        let move = CGAffineTransform(translationX: 0, y: 20)
        try h.engine.apply(#require(h.engine.snapshots[page]).page.transformEdit([mark.id], by: move), to: page)
        h.engine.setSelectionPreview(nil)
        // Highlights alone: back at once, image gone at once (no canvas render to wait for).
        #expect(h.engine.selection.lifted.isHidden)
        #expect(h.engine.selection.liftedHighlights.isEmpty)
        let after = try #require(view.highlightShapeLayers.first)
        #expect(abs(after.frame.minY - (before.minY + 20)) < 1e-3)
    }

    @Test func liftedHighlightWaitsForInkToLandBeforeReturning() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let mark = RenderFixtures.line(2, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 320, y: 50), tool: .highlighter, width: 16)
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([mark]), to: page)
        let view = try #require(h.engine.pageViews[page])
        let canvas = try #require(h.canvas(1))
        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [mark.id, RenderFixtures.strokeID(9)]))
        #expect(view.highlightShapeLayers.isEmpty)
        #expect(canvas.ids.isEmpty)
        h.engine.setSelectionPreview(nil)
        // The ink is back on the canvas, but the image stays until it has drawn, and so does the highlight.
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        #expect(!h.engine.selection.lifted.isHidden)
        #expect(h.engine.selection.liftedHighlights == [mark.id])
        #expect(view.highlightShapeLayers.isEmpty)
        h.engine.canvasViewDidFinishRendering(canvas.view)
        #expect(h.engine.selection.lifted.isHidden)
        #expect(h.engine.selection.liftedHighlights.isEmpty)
        #expect(view.highlightShapeLayers.count == 1)
    }

    @Test func themeChangeRecolorsWithoutRebuildingPaths() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([Fixtures.highlight]), to: page)
        let view = try #require(h.engine.pageViews[page])
        let layer = try #require(view.highlightShapeLayers.first)
        let light = layer.fillColor
        h.engine.setTheme(.night)
        #expect(view.highlightShapeLayers.first === layer)
        #expect(layer.fillColor != light)
        #expect(layer.fillColor == Highlight.color(UIColor(FixturePalette().ink(.semantic(.red), on: .night))))
    }

    /// Pre-#120 highlights (PencilKit's marker chisel) draw as bands at their widest extent.
    @Test func markerHighlightsFromOlderFilesDrawAsBands() throws {
        let legacy = Stroke(
            id: RenderFixtures.strokeID(6), tool: .highlighter, color: .semantic(.red), width: 16, samples: Fixtures.highlight.samples,
            rendering: StrokeRendering(
                ink: StrokeRendering.Ink.marker, randomSeed: 1,
                points: Array(repeating: PointRendering(width: 20.6, height: 20.6), count: Fixtures.highlight.samples.count)
            )
        )
        let shape = try #require(Highlight.shape(of: legacy))
        #expect(abs(shape.path.boundingBox.height + shape.rim - (1.45 * 20.6 - 0.5)) < 1e-3)
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([legacy]), to: page)
        #expect(h.canvas(1)?.ids == [RenderFixtures.strokeID(9)])
        #expect(h.engine.pageViews[page]?.highlightShapeLayers.count == 1)
    }
}
