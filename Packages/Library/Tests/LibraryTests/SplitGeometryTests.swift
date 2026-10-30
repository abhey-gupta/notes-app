import CoreGraphics
@testable import Library
import Testing

struct SplitGeometryTests {
    private let landscape = SplitGeometry(size: CGSize(width: 1194, height: 834))
    private let portrait = SplitGeometry(size: CGSize(width: 834, height: 1194))

    @Test func axisFollowsShape() {
        #expect(landscape.axis == .horizontal)
        #expect(portrait.axis == .vertical)
    }

    @Test func framesLeaveTheDividerBetween() {
        let (primary, secondary) = landscape.frames(SplitGeometry.half)
        #expect(primary == CGRect(x: 0, y: 0, width: 597, height: 834))
        #expect(secondary == CGRect(x: 598, y: 0, width: 596, height: 834))
        let stacked = portrait.frames(SplitGeometry.half)
        #expect(stacked.primary == CGRect(x: 0, y: 0, width: 834, height: 597))
        #expect(stacked.secondary.minY == 598)
        #expect(stacked.secondary.maxY == 1194)
    }

    @Test func dragClingsToStops() {
        let near = landscape.drag(to: landscape.position(1.0 / 3) + 10)
        #expect(near.stop == 1.0 / 3)
        #expect(near.fraction == 1.0 / 3)
        let free = landscape.drag(to: 500)
        #expect(free.stop == nil)
        #expect(abs(free.fraction - 500 / 1194) < 1e-9)
        #expect(landscape.drag(to: -40).fraction == 0, "clamped to the editor")
    }

    @Test func releaseLandsOnNearestStopOrCloses() {
        #expect(landscape.release(at: 560, velocity: 0) == .rest(SplitGeometry.half))
        #expect(landscape.release(at: 700, velocity: 0) == .rest(2.0 / 3))
        #expect(landscape.release(at: 560, velocity: 2000) == .rest(2.0 / 3), "a flick carries")
        #expect(landscape.release(at: 100, velocity: 0) == .close(.primary))
        #expect(landscape.release(at: 1100, velocity: 0) == .close(.secondary))
        #expect(landscape.release(at: 900, velocity: 2500) == .close(.secondary))
    }

    @Test func closingProgress() {
        #expect(landscape.closing(0.5) == nil)
        #expect(landscape.closing(0)?.pane == .primary)
        #expect(landscape.closing(0)?.progress == 1)
        let going = landscape.closing(0.95)
        #expect(going?.pane == .secondary)
        #expect(abs((going?.progress ?? 0) - 2.0 / 3) < 1e-9)
    }
}
