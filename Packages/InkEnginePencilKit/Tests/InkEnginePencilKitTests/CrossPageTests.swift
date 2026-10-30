import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing
import UIKit

/// A stroke running from page 2 onto page 3 without lifting (#163): shown over both pages while drawn,
/// committed as one piece per page in one report. The harness shows page 2 (content y 866...1708) and
/// page 3 (1732...) at zoom 1.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct CrossPageTests {
    /// Page 2 y 800 → page 3 y 34 (content 1666 → 1766), in page 2's space.
    static let across = RenderFixtures.line(1, from: CGPoint(x: 100, y: 800), to: CGPoint(x: 100, y: 900))

    let h: Harness

    init() {
        h = Harness()
        h.scroll(toY: 900)
    }

    @Test func pencilKitStrokeIsCommittedAsOnePiecePerPage() throws {
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint), color: .semantic(.blue), width: 3))
        let (page2, page3) = try (#require(h.canvas(1)), #require(h.canvas(2)))
        h.userDraws(Self.across, on: 1)

        #expect(h.recorder.commitCalls == 1, "one stroke, one report: one undo step")
        try #require(h.recorder.commits.count == 2)
        let (first, firstPage) = h.recorder.commits[0]
        let (second, secondPage) = h.recorder.commits[1]
        #expect(firstPage == h.frames[1].id)
        #expect(secondPage == h.frames[2].id)
        #expect(first.samples.allSatisfy { $0.y >= 800 && $0.y <= 866 })
        #expect(second.samples.first?.y == 0, "page 3's piece starts at its top edge, in its own space")
        #expect(abs((second.samples.last?.y ?? 0) - 34) < 0.01)
        #expect(second.tool == .ballpoint && second.color == .semantic(.blue))

        // Each canvas draws its own piece as pending.
        #expect(page2.ids == [RenderFixtures.strokeID(9), first.id])
        #expect(page2.view.drawing.strokes.count == 2)
        #expect((page2.view.drawing.strokes.last?.renderBounds.maxY ?? 0) < 900, "page 2 no longer holds page 3's part")
        #expect(page3.ids == [second.id])
        #expect(page3.view.drawing.strokes.count == 1)

        // The echo keeps both canvases.
        let rebuilds = h.engine.rebuildCount
        for (stroke, page) in h.recorder.commits {
            try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([stroke]), to: page)
        }
        #expect(h.engine.rebuildCount == rebuilds)
        let drained = h.engine.pending.values.allSatisfy(\.isEmpty)
        #expect(drained)
    }

    @Test func strokeOnOnePageIsCommittedWhole() {
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint)))
        let stroke = RenderFixtures.line(2, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 120))
        h.userDraws(stroke, on: 1)
        #expect(h.recorder.commitCalls == 1)
        #expect(h.recorder.commits.map(\.1) == [h.frames[1].id])
        #expect(h.recorder.commits.first?.0.samples.count == stroke.samples.count)
    }

    @Test func pencilKitStrokeIsShownOverTheNextPageWhileDrawn() throws {
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint), color: .semantic(.blue), width: 3))
        let at = { (y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: 100, y: y), timestamp: t) }
        #expect(h.engine.crossPageTouchBegan(at(1666, 0)))
        h.engine.crossPageTouchMoved([at(1690, 0.01), at(1700, 0.02)])
        #expect(h.engine.crossPage.layer.isHidden, "still on its page: the canvas draws it all")

        h.engine.crossPageTouchMoved([at(1740, 0.03), at(1766, 0.04)])
        let layer = h.engine.crossPage.layer
        #expect(!layer.isHidden)
        #expect(layer.contents != nil)
        #expect(layer.frame.minY >= 1732, "only over page 3: page 2's canvas draws its part")
        #expect(layer.frame.contains(CGPoint(x: 100, y: 1750)))

        // Lift: the image stays until page 3's canvas has drawn its piece.
        h.engine.crossPageTouchEnded(cancelled: false)
        #expect(!layer.isHidden)
        h.userDraws(Self.across, on: 1)
        #expect(!layer.isHidden)
        try h.engine.canvasViewDidFinishRendering(#require(h.canvas(2)).view)
        #expect(layer.isHidden)
    }

    @Test func fingerOrOtherToolsAreNotFollowed() {
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint), pressure: false))
        #expect(!h.engine.crossPageTouchBegan(TouchRecord(id: TouchID(1), location: CGPoint(x: 100, y: 1666), timestamp: 0)))
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint)))
        let finger = TouchRecord(id: TouchID(2), kind: .direct, location: CGPoint(x: 100, y: 1666), timestamp: 0)
        #expect(!h.engine.crossPageTouchBegan(finger))
    }

    @Test func pressureOffStrokeIsDrawnAcrossAndCommittedPerPage() throws {
        h.engine.setTool(FlatPenTests.flat)
        var tracker = InkInputTracker()
        tracker.recordsForce = false
        let at = { (y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: 100, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        send(tracker.began(at(1666, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(1766, 0.02), coalesced: [at(1720, 0.01), at(1766, 0.02)]))
        let image = h.engine.selection.flatPen
        #expect(!image.isHidden)
        #expect(image.frame.contains(CGPoint(x: 100, y: 1680)))
        #expect(image.frame.contains(CGPoint(x: 100, y: 1750)), "on page 3 too")
        #expect(image.mask != nil, "kept off the gap between the pages")

        send(tracker.ended(at(1766, 0.03)))
        #expect(h.recorder.commitCalls == 1)
        #expect(h.recorder.commits.map(\.1) == [h.frames[1].id, h.frames[2].id])
        #expect(h.engine.selection.flatPenAwaiting == [h.frames[1].id, h.frames[2].id])
        try h.engine.canvasViewDidFinishRendering(#require(h.canvas(1)).view)
        #expect(!image.isHidden, "page 3 hasn't drawn its piece yet")
        try h.engine.canvasViewDidFinishRendering(#require(h.canvas(2)).view)
        #expect(image.isHidden)
        try #expect(#require(h.canvas(2)).ids == [h.recorder.commits[1].0.id])
    }

    @Test func highlightIsBandedOnEachPageAndCommittedPerPage() throws {
        h.engine.setTool(HighlighterFixtures.tool)
        var tracker = InkInputTracker()
        let at = { (y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: 100, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        let page3 = try #require(h.engine.pageViews[h.frames[2].id])
        send(tracker.began(at(1666, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(1700, 0.01), coalesced: [at(1700, 0.01)]))
        #expect(h.engine.crossPage.bands.isEmpty)
        send(tracker.moved(at(1766, 0.02), coalesced: [at(1740, 0.015), at(1766, 0.02)]))
        let band = try #require(h.engine.crossPage.bands[h.frames[2].id])
        #expect(page3.highlightShapeLayers == [band])
        #expect(band.frame.contains(CGPoint(x: 100, y: 20)), "in page 3's space")

        send(tracker.ended(at(1766, 0.03)))
        #expect(h.recorder.commitCalls == 1)
        #expect(h.recorder.commits.map(\.1) == [h.frames[1].id, h.frames[2].id])
        #expect(h.engine.crossPage.bands.isEmpty)
        #expect(page3.highlightShapeLayers == [band], "the band is page 3's piece now")
        h.engine.layoutPages()
        #expect(page3.highlightShapeLayers == [band])
    }

    @Test func cancelledHighlightLeavesNoBands() throws {
        h.engine.setTool(HighlighterFixtures.tool)
        var tracker = InkInputTracker()
        let at = { (y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: 100, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        let page3 = try #require(h.engine.pageViews[h.frames[2].id])
        send(tracker.began(at(1666, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(1766, 0.02), coalesced: [at(1766, 0.02)]))
        #expect(page3.highlightShapeLayers.count == 1)
        send(tracker.cancelled(at(1766, 0.03)))
        h.engine.layoutPages()
        #expect(page3.highlightShapeLayers.isEmpty)
        #expect(h.recorder.commits.isEmpty)
    }
}
