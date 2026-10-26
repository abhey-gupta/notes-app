import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import Testing

@MainActor
struct EraserCursorTests {
    @Test func eraserCursorShowsReachUnderTipAndHidesOnLift() throws {
        let h = Harness()
        h.scroll(toY: 900, zoom: 2)
        h.engine.setTool(ToolConfiguration(tool: .eraser, width: 20))
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        let cursor = h.engine.selection.eraser
        #expect(cursor.opacity == 0)
        send(tracker.began(at(100, 1000, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(120, 1000, 0.01)))
        #expect(cursor.opacity == 1)
        #expect(try #require(cursor.path).boundingBox == CGRect(x: 110, y: 990, width: 20, height: 20))
        #expect(cursor.lineWidth == 0.5)
        send(tracker.ended(at(120, 1000, 0.02)))
        #expect(cursor.opacity == 0)

        h.engine.showEraserCursor(at: CGPoint(x: 50, y: 50))
        #expect(cursor.opacity == 1)
        h.engine.setTool(ToolConfiguration(tool: .lasso))
        #expect(cursor.opacity == 0)
        h.engine.showEraserCursor(at: CGPoint(x: 50, y: 50))
        #expect(cursor.opacity == 0)
    }
}
