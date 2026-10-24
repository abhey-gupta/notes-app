@testable import Canvas
import Testing

/// The canvas stays held from the first pinch frame until the scroll view is at rest after the release
/// (real iPad: settling mid-deceleration drifted the ink off the paper, then it snapped back).
struct ZoomHoldTests {
    private func holds(
        pinching: Bool = false,
        bouncing: Bool = false,
        held: Bool = false,
        dragging: Bool = false,
        decelerating: Bool = false
    ) -> Bool {
        ZoomHold.holds(pinching: pinching, zoomBouncing: bouncing, held: held, dragging: dragging, decelerating: decelerating)
    }

    @Test func pinchAndZoomBounceAlwaysHold() {
        #expect(holds(pinching: true))
        #expect(holds(bouncing: true))
        #expect(holds(pinching: true, held: true, dragging: true))
    }

    @Test func releaseKeepsTheHoldWhileThePageMoves() {
        #expect(holds(held: true, dragging: true), "one finger still down after the pinch")
        #expect(holds(held: true, decelerating: true), "flick deceleration or rubber band after the release")
        #expect(!holds(held: true), "at rest: settle")
    }

    @Test func plainScrollsNeverStartAHold() {
        #expect(!holds(dragging: true))
        #expect(!holds(decelerating: true))
        #expect(!holds())
    }
}
