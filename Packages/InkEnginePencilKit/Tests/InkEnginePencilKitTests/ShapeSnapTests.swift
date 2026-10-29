import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkGeometry
import InkModel
import PencilKit
import Testing
import UIKit

/// Hold to snap (#165): a held stroke becomes a perfect shape that follows the Pencil until lift, and
/// commits in place of the freehand stroke, which is never reported.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct ShapeSnapTests {
    static let flat = ToolConfiguration(tool: .pen(.ballpoint), color: .semantic(.blue), width: 3, pressure: false)
    static let pen = ToolConfiguration(tool: .pen(.ballpoint), color: .semantic(.blue), width: 3)
    static let highlighter = ToolConfiguration(tool: .pen(.highlighter), color: .semantic(.accent), width: 12)

    /// A rough rectangle on page 3 (content y 1732...), in content space, ending back near its start.
    static let rectangle: [CGPoint] = {
        let corners = [CGPoint(x: 100, y: 1800), CGPoint(x: 400, y: 1803), CGPoint(x: 398, y: 2000), CGPoint(x: 101, y: 1998)]
        var points: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst() + [CGPoint(x: 100, y: 1806)]) {
            points += (0 ..< 30).map { i in CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 30, y: a.y + (b.y - a.y) * CGFloat(i) / 30) }
        }
        return points + [CGPoint(x: 100, y: 1806)]
    }()

    /// Sends `points` through the hold gesture's handlers (and the input view, when the tool draws there)
    /// as one touch. Returns the input tracker so the caller can end the stroke.
    private static func draw(_ points: [CGPoint], _ h: Harness, through input: Bool) -> InkInputTracker {
        var tracker = InkInputTracker()
        tracker.recordsForce = h.engine.input.recordsForce
        let record = { (i: Int) in TouchRecord(id: TouchID(1), location: points[i], timestamp: CACurrentMediaTime() + Double(i) * 0.004) }
        #expect(h.engine.shapeTouchBegan(record(0)))
        if input {
            send(tracker.began(record(0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) }, h)
        }
        for i in points.indices.dropFirst() {
            h.engine.shapeTouchMoved([record(i)])
            if input {
                send(tracker.moved(record(i)), h)
            }
        }
        return tracker
    }

    private static func send(_ events: [InkInputTracker.Event], _ h: Harness) {
        for event in events {
            h.engine.inkInputView(h.engine.input, didProduce: event)
        }
    }

    private static func isRectangle(_ stroke: Stroke) -> Bool {
        let points = stroke.samples.map { Point2($0.x, $0.y) }
        guard case let .polygon(corners) = ShapeRecognizer.recognize(points), corners.count == 4 else { return false }
        return abs(corners[0].y - corners[1].y) < 0.01 && points.first == points.last
    }

    @Test func heldPressureOffStrokeSnapsFollowsAndCommitsTheShapeOnly() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.flat)
        let canvas = try #require(h.canvas(2))
        var tracker = Self.draw(Self.rectangle, h, through: true)
        #expect(h.engine.selection.flatPenLive != nil)

        h.engine.shapeHoldElapsed()
        let session = try #require(h.engine.shapeSnap.session)
        #expect(h.engine.selection.flatPenLive == nil, "the freehand stroke is cut")
        #expect(!h.engine.selection.flatPen.isHidden, "the shape shows in its place")
        #expect(h.recorder.commits.isEmpty)

        // Dragging the anchor corner out grows the rectangle.
        let before = session.stroke.bounds
        h.engine.shapeTouchMoved([TouchRecord(id: TouchID(1), location: CGPoint(x: 80, y: 1790), timestamp: CACurrentMediaTime())])
        let after = try #require(h.engine.shapeSnap.session).stroke.bounds
        #expect(after.width > before.width && after.height > before.height)

        h.engine.shapeTouchEnded()
        Self.send(tracker.ended(TouchRecord(id: TouchID(1), location: CGPoint(x: 80, y: 1790), timestamp: CACurrentMediaTime())), h)
        let (stroke, page) = try #require(h.recorder.commits.first)
        #expect(h.recorder.commits.count == 1, "only the shape is committed")
        #expect(page == h.frames[2].id)
        #expect(stroke.id == session.template.id)
        #expect(Self.isRectangle(stroke))
        #expect(stroke.samples.allSatisfy { $0.force == Sample.neutralForce })
        #expect(try Set(#require(stroke.rendering).points.map(\.width)).count == 1, "constant width")
        #expect(canvas.ids.last == stroke.id, "drawn by the canvas as pending")
        #expect(h.engine.shapeSnap.session == nil)
    }

    @Test func heldPencilKitStrokeIsCutAndWhatPencilKitKeepsOfItDropped() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        let canvas = try #require(h.canvas(2))
        let shown = canvas.view.drawing.strokes.count
        h.engine.canvasViewDidBeginUsingTool(canvas.view)
        _ = Self.draw(Self.rectangle, h, through: false)

        h.engine.shapeHoldElapsed()
        #expect(canvas.discardsStroke)
        #expect(!h.engine.selection.flatPen.isHidden)
        // PencilKit may keep the cancelled stroke: it is dropped, not reported.
        var drawing = canvas.view.drawing
        let freehand = RenderFixtures.line(3, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))
        drawing.strokes.append(PencilKitConversion.pkStroke(from: freehand, color: .black))
        canvas.view.drawing = drawing
        h.engine.canvasViewDrawingDidChange(canvas.view)
        h.engine.canvasViewDidEndUsingTool(canvas.view)
        #expect(canvas.view.drawing.strokes.count == shown)
        #expect(h.recorder.commits.isEmpty)

        h.engine.shapeTouchEnded()
        let stroke = try #require(h.recorder.commits.first?.0)
        #expect(h.recorder.commits.count == 1)
        #expect(Self.isRectangle(stroke))
        #expect(canvas.view.drawing.strokes.count == shown + 1)
        #expect(canvas.ids.last == stroke.id)

        // The next stroke is PencilKit's own again.
        h.engine.canvasViewDidBeginUsingTool(canvas.view)
        #expect(!canvas.discardsStroke)
        h.userDraws(freehand, on: 2)
        #expect(h.recorder.commits.count == 2)
    }

    @Test func heldHighlightSnapsToABand() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.highlighter)
        _ = Self.draw(Self.rectangle, h, through: true)
        #expect(h.engine.selection.liveHighlight != nil)

        h.engine.shapeHoldElapsed()
        #expect(h.engine.selection.liveHighlight == nil, "the freehand band is cut")
        let layer = try #require(h.engine.shapeSnap.session?.layer)
        #expect(layer.superlayer != nil)
        #expect(layer.animationKeys() == nil, "the shape's band appears at once, no fade in")

        h.engine.shapeTouchEnded()
        let stroke = try #require(h.recorder.commits.first?.0)
        #expect(h.recorder.commits.count == 1)
        #expect(Highlight.isHighlight(stroke))
        #expect(Self.isRectangle(stroke))
        #expect(layer.superlayer != nil, "the live band becomes the stroke's own")
    }

    @Test func movingStrokesScribblesAndOtherToolsDontSnap() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.flat)
        // Still moving: the hold check finds the touch moved since.
        _ = Self.draw(Self.rectangle, h, through: true)
        let tracking = try #require(h.engine.shapeSnap.tracking)
        #expect(tracking.stillSince > CACurrentMediaTime(), "the last move restarted the hold")

        // A scribble never snaps.
        let zigzag = (0 ..< 40).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 1800 + ($0.isMultiple(of: 2) ? 0 : 60)) }
        _ = Self.draw(zigzag, h, through: true)
        h.engine.shapeHoldElapsed()
        #expect(h.engine.shapeSnap.session == nil)
        #expect(h.engine.selection.flatPenLive != nil, "the freehand stroke goes on")

        // Eraser, lasso, and the setting off: not tracked.
        for tool in [ToolConfiguration(tool: .eraser, width: 20), ToolConfiguration(tool: .lasso), {
            var off = Self.flat
            off.snapsShapes = false
            return off
        }()] {
            h.engine.setTool(tool)
            #expect(!h.engine.shapeTouchBegan(TouchRecord(id: TouchID(2), location: CGPoint(x: 100, y: 1800), timestamp: 0)))
        }
    }

    @Test func fingersDontSnapUnlessTheyDraw() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        let finger = TouchRecord(id: TouchID(3), kind: .direct, location: CGPoint(x: 100, y: 1800), timestamp: 0)
        #expect(!h.engine.shapeTouchBegan(finger), "a resting palm or a scrolling finger")
        var drawing = Self.pen
        drawing.allowsFingerDrawing = true
        h.engine.setTool(drawing)
        #expect(h.engine.shapeTouchBegan(finger))
    }

    @Test func toolChangeOrCancelDropsTheShape() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.flat)
        _ = Self.draw(Self.rectangle, h, through: true)
        h.engine.shapeHoldElapsed()
        #expect(h.engine.shapeSnap.session != nil)
        h.engine.cancelShapeSnap()
        #expect(h.engine.selection.flatPen.isHidden)
        h.engine.shapeTouchEnded()
        #expect(h.recorder.commits.isEmpty)

        h.engine.setTool(Self.highlighter)
        _ = Self.draw(Self.rectangle, h, through: true)
        h.engine.shapeHoldElapsed()
        let layer = try #require(h.engine.shapeSnap.session?.layer)
        h.engine.setTool(ToolConfiguration(tool: .eraser, width: 20))
        #expect(layer.superlayer == nil)
        #expect(h.engine.shapeSnap.session == nil)
        #expect(h.recorder.commits.isEmpty)
    }
}
