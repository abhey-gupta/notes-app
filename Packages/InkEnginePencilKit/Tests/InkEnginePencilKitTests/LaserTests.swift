import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import QuartzCore
import Testing

struct LaserTrailTests {
    private func trail(_ times: [Double]) -> LaserTrail {
        var trail = LaserTrail()
        for (i, t) in times.enumerated() {
            trail.append(CGPoint(x: Double(i) * 10, y: 0), at: t)
        }
        return trail
    }

    /// Opacity falls with age: the newest run is brightest, runs join end to end.
    @Test func bandsFadeWithAge() throws {
        let trail = trail([0, 0.1, 0.2, 0.3, 0.4, 0.5])
        let bands = trail.bands(now: 0.5)
        #expect(bands.count > 1)
        #expect(bands.map(\.opacity) == bands.map(\.opacity).sorted(), "oldest first, faintest first")
        #expect(try #require(bands.last).points.last == CGPoint(x: 50, y: 0))
        for (older, newer) in zip(bands, bands.dropFirst()) {
            #expect(older.points.last == newer.points.first, "no gap between runs")
        }
    }

    /// The tail ages out while the tip moves, and the whole trail is gone a lifetime after the last point.
    @Test func pruneDropsExpiredPointsButKeepsTheTailAnchor() {
        var trail = trail([0, 0.1, 0.2, 0.9])
        trail.prune(now: 0.75)
        #expect(trail.points.map(\.point.x) == [10, 20, 30], "one expired point stays to anchor the fade")
        trail.prune(now: 0.9 + LaserTrail.lifetime)
        #expect(trail.isEmpty)
    }

    /// A tip resting in place adds no points but stays alive.
    @Test func restingTipRefreshesInsteadOfAppending() {
        var trail = LaserTrail()
        trail.append(.zero, at: 0)
        trail.append(CGPoint(x: 0.1, y: 0), at: 0.5)
        #expect(trail.points.count == 1 && trail.points[0].time == 0.5)
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
        #expect(laser.tip.opacity == 1 && laser.layer.opacity == 1)
        #expect(try #require(laser.tip.path).boundingBox.midX == 180)
        #expect(laser.trail.points.count == 3)
        #expect(laser.isAnimating)
        send(tracker.ended(at(180, 120, now + 0.03)))
        #expect(laser.tip.opacity == 0, "tip fades on lift")
        #expect(h.recorder.commits.isEmpty && h.recorder.eraser.isEmpty && h.recorder.lassos.isEmpty, "nothing reaches the document")

        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint)))
        #expect(laser.trail.isEmpty && !laser.isAnimating && laser.layer.opacity == 0)
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
        #expect(h.engine.laser.trail.isEmpty && h.engine.laser.tip.opacity == 1)
    }
}
