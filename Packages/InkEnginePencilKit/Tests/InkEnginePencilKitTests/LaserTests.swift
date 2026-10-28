import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import QuartzCore
import Testing

struct LaserTrailTests {
    private func drawn(_ xs: [CGFloat], into trail: inout LaserTrail, at time: TimeInterval) {
        trail.begin(at: time)
        for x in xs {
            trail.append(CGPoint(x: x, y: 0))
        }
    }

    /// Fully bright while the Pencil touches, however long; fades linearly after lift.
    @Test func brightWhileTouchingFadesAfterLift() {
        var trail = LaserTrail()
        drawn([0, 10, 20], into: &trail, at: 0)
        #expect(trail.opacity(at: 30) == 1)
        trail.lift(at: 30)
        #expect(trail.opacity(at: 30) == 1)
        #expect(abs(trail.opacity(at: 30 + LaserTrail.fadeDuration / 2) - 0.5) < 0.001)
        #expect(trail.opacity(at: 30 + LaserTrail.fadeDuration + 0.001) == 0)
    }

    /// Touching again mid-fade restores full brightness and keeps the old trail; after it is gone it starts empty.
    @Test func touchMidFadeRestoresTrail() {
        var trail = LaserTrail()
        drawn([0, 10], into: &trail, at: 0)
        trail.lift(at: 1)
        drawn([50, 60], into: &trail, at: 1 + LaserTrail.fadeDuration * 0.9)
        #expect(trail.opacity(at: 5) == 1)
        #expect(trail.strokes == [[CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)], [CGPoint(x: 50, y: 0), CGPoint(x: 60, y: 0)]])
        trail.lift(at: 5)
        drawn([90, 100], into: &trail, at: 5 + LaserTrail.fadeDuration)
        #expect(trail.strokes == [[CGPoint(x: 90, y: 0), CGPoint(x: 100, y: 0)]])
    }

    /// A resting tip adds nothing; a tap alone draws no line.
    @Test func restingTipAndTapAddNothing() {
        var trail = LaserTrail()
        drawn([0, 0.1, 0.2], into: &trail, at: 0)
        #expect(trail.strokes == [[.zero]])
        #expect(trail.isEmpty)
    }
}

@MainActor
struct LaserEngineTests {
    @Test func laserDrawsTipAndTrailWithoutCommitting() throws {
        let h = Harness()
        h.scroll(toY: 0)
        h.engine.setTool(ToolConfiguration(tool: .laser(trail: true)))
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        let now = CACurrentMediaTime()
        send(tracker.began(at(100, 100, now)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(140, 100, now + 0.01)))
        send(tracker.moved(at(180, 120, now + 0.02)))
        let laser = h.engine.laser
        #expect(laser.layer.opacity == 1 && laser.layer.animation(forKey: "fade") == nil)
        #expect(try #require(laser.tip.last?.path).boundingBox.midX == 180)
        #expect(laser.trail.strokes.map(\.count) == [3])
        send(tracker.ended(at(180, 120, now + 0.03)))
        #expect(laser.layer.opacity == 0 && laser.layer.animation(forKey: "fade")?.duration == LaserTrail.fadeDuration)
        let tipHidden = laser.tip.allSatisfy(\.isHidden)
        #expect(tipHidden, "tip goes on lift, trail fades")
        #expect(h.recorder.commits.isEmpty && h.recorder.eraser.isEmpty && h.recorder.lassos.isEmpty, "nothing reaches the document")

        var again = InkInputTracker()
        let at2 = { (x: CGFloat, t: Double) in TouchRecord(id: TouchID(2), location: CGPoint(x: x, y: 200), timestamp: t) }
        for event in again.began(at2(100, now + 0.1), target: { h.engine.inkInputView(h.engine.input, targetAt: $0) }) {
            h.engine.inkInputView(h.engine.input, didProduce: event)
        }
        #expect(laser.layer.opacity == 1 && laser.layer.animation(forKey: "fade") == nil, "bright again mid-fade")
        #expect(laser.trail.strokes.count == 2, "old trail kept")

        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint)))
        #expect(laser.trail.isEmpty && laser.layer.opacity == 0)
    }

    @Test func dotModeKeepsNoTrail() {
        let h = Harness()
        h.scroll(toY: 0)
        h.engine.setTool(ToolConfiguration(tool: .laser(trail: false)))
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: 100), timestamp: t) }
        for event in tracker.began(at(100, 0), target: { h.engine.inkInputView(h.engine.input, targetAt: $0) }) + tracker.moved(at(
            150,
            0.01
        )) {
            h.engine.inkInputView(h.engine.input, didProduce: event)
        }
        #expect(h.engine.laser.trail.isEmpty && h.engine.laser.layer.opacity == 1)
    }
}
