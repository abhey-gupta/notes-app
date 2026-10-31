import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing
import UIKit

/// Hold to erase (#211): a pen touch held still where it went down cuts its dot, asks for the eraser and, once
/// the eraser is set, erases along the rest of the touch.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct HoldEraseTests {
    static let pen = ToolConfiguration(tool: .pen(.ballpoint), color: .semantic(.blue), width: 3)
    static let flat = ToolConfiguration(tool: .pen(.ballpoint), color: .semantic(.blue), width: 3, pressure: false)
    static let eraser = ToolConfiguration(tool: .eraser, width: 20)

    /// A point on page 3 (content y 1732...), in content space.
    static func touch(_ x: CGFloat, _ y: CGFloat = 1800, id: UInt = 1) -> TouchRecord {
        TouchRecord(id: TouchID(id), location: CGPoint(x: x, y: y), timestamp: CACurrentMediaTime())
    }

    /// Erased points in content space, in order.
    private static func erased(_ h: Harness) -> [CGPoint] {
        h.recorder.eraser.flatMap { samples, page in
            let origin = h.frames.first { $0.id == page }?.frame.origin ?? .zero
            return samples.map { CGPoint(x: origin.x + CGFloat($0.x), y: origin.y + CGFloat($0.y)) }
        }
    }

    @Test func heldPencilKitTouchCutsItsDotAndErasesOnceTheEraserIsSet() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        let canvas = try #require(h.canvas(2))
        h.engine.canvasViewDidBeginUsingTool(canvas.view)
        #expect(h.engine.holdTouchBegan(Self.touch(200)))
        h.engine.holdTouchMoved([Self.touch(202, 1801)]) // the tip resting, not moving

        h.engine.holdElapsed()
        #expect(h.recorder.holds == 1)
        #expect(canvas.discardsStroke, "the dot is cut")
        #expect(h.recorder.eraser.isEmpty, "nothing erased before the eraser is set")
        h.engine.holdTouchMoved([Self.touch(240)])

        let begins = h.recorder.begins
        h.engine.setTool(Self.eraser)
        #expect(h.recorder.begins == begins + 1, "a new eraser gesture")
        #expect(Self.erased(h).map(\.x) == [200, 240], "from where it went down, with the moves while held")
        #expect(h.recorder.eraser.allSatisfy { $0.1 == h.frames[2].id })
        #expect(h.engine.selection.eraser.opacity == 1, "the eraser cursor shows")

        h.engine.holdTouchMoved([Self.touch(300)])
        #expect(Self.erased(h).last?.x == 300)
        h.engine.holdTouchEnded(cancelled: false)
        #expect(h.engine.holdErase.start == nil)
        h.engine.holdTouchMoved([Self.touch(400)])
        #expect(Self.erased(h).last?.x == 300, "the touch is no longer followed")
    }

    @Test func toolSwitchedInsideTheCallbackErasesAtOnce() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        h.recorder.onHold = { h.engine.setTool(Self.eraser) }
        h.engine.holdTouchBegan(Self.touch(200))
        h.engine.holdElapsed()
        #expect(Self.erased(h).map(\.x) == [200])
        h.engine.holdTouchMoved([Self.touch(260)])
        #expect(Self.erased(h).map(\.x) == [200, 260])
    }

    @Test func heldFlatPenStrokeIsCut() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.flat)
        var tracker = InkInputTracker()
        tracker.recordsForce = false
        for event in tracker.began(Self.touch(200)) { h.engine.inkInputView(h.engine.input, targetAt: $0) } {
            h.engine.inkInputView(h.engine.input, didProduce: event)
        }
        #expect(h.engine.selection.flatPenLive != nil)
        h.engine.holdTouchBegan(Self.touch(200))
        h.engine.holdElapsed()
        #expect(h.engine.selection.flatPenLive == nil)
        #expect(h.recorder.commits.isEmpty)
    }

    @Test func movingTouchesOtherToolsAndTheSettingOffDontHold() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        h.engine.holdTouchBegan(Self.touch(200))
        h.engine.holdTouchMoved([Self.touch(210)])
        h.engine.holdElapsed()
        #expect(h.recorder.holds == 0, "moved past the tolerance: a stroke, not a hold")

        // Zoomed in, the tolerance is in screen points: 3 content pt at 2× is 6 on screen.
        h.scroll(toY: 900, zoom: 2)
        h.engine.holdTouchBegan(Self.touch(200))
        h.engine.holdTouchMoved([Self.touch(203)])
        h.engine.holdElapsed()
        #expect(h.recorder.holds == 0)

        var off = Self.pen
        off.holdsToErase = false
        for tool in [Self.eraser, ToolConfiguration(tool: .lasso), ToolConfiguration(tool: .laser(trail: true)), off] {
            h.engine.setTool(tool)
            #expect(!h.engine.holdTouchBegan(Self.touch(200)))
        }
        h.engine.setTool(Self.pen)
        #expect(
            !h.engine.holdTouchBegan(TouchRecord(id: TouchID(3), kind: .direct, location: CGPoint(x: 200, y: 1800), timestamp: 0)),
            "a resting palm"
        )
    }

    @Test func liftBeforeTheEraserArrivesErasesNothing() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        h.engine.holdTouchBegan(Self.touch(200))
        h.engine.holdElapsed()
        h.engine.holdTouchEnded(cancelled: false)
        h.engine.setTool(Self.eraser)
        #expect(h.recorder.eraser.isEmpty)
    }

    @Test func otherToolWhileErasingEndsTheStroke() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(Self.pen)
        h.engine.holdTouchBegan(Self.touch(200))
        h.engine.holdElapsed()
        h.engine.setTool(Self.eraser)
        h.engine.setTool(Self.pen)
        h.engine.holdTouchMoved([Self.touch(260)])
        #expect(Self.erased(h).map(\.x) == [200])
        #expect(h.engine.holdErase.start == nil)
    }
}
