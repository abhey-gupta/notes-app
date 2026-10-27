@testable import Canvas
import CoreGraphics
import Testing

/// Multi-finger taps spotted from raw touches (#121).
struct FingerTapTests {
    private let p = CGPoint(x: 100, y: 100)

    @Test func twoFingersDownAndUpQuicklyTap() {
        var tap = FingerTap()
        tap.began(1, at: p, time: 10)
        tap.began(2, at: p, time: 10.02)
        #expect(tap.ended(1, at: p, time: 10.1) == nil, "one finger still down")
        #expect(tap.ended(2, at: p, time: 10.12) == 2)
    }

    @Test func threeFingersTap() {
        var tap = FingerTap()
        for id in 1 ... 3 {
            tap.began(id, at: p, time: 5)
        }
        _ = tap.ended(1, at: p, time: 5.1)
        _ = tap.ended(2, at: p, time: 5.1)
        #expect(tap.ended(3, at: p, time: 5.1) == 3)
    }

    @Test func movingFingersArePinchOrScroll() {
        var tap = FingerTap()
        tap.began(1, at: p, time: 0)
        tap.began(2, at: CGPoint(x: 200, y: 100), time: 0)
        tap.moved(2, to: CGPoint(x: 230, y: 100))
        _ = tap.ended(1, at: p, time: 0.1)
        #expect(tap.ended(2, at: CGPoint(x: 230, y: 100), time: 0.1) == nil)
    }

    @Test func smallDriftStillTaps() {
        var tap = FingerTap()
        tap.began(1, at: p, time: 0)
        tap.began(2, at: p, time: 0)
        _ = tap.ended(1, at: CGPoint(x: 105, y: 106), time: 0.1)
        #expect(tap.ended(2, at: p, time: 0.1) == 2)
    }

    @Test func holdingTooLongIsNoTap() {
        var tap = FingerTap()
        tap.began(1, at: p, time: 0)
        tap.began(2, at: p, time: 0)
        _ = tap.ended(1, at: p, time: 0.5)
        #expect(tap.ended(2, at: p, time: 0.5) == nil)
    }

    @Test func invalidatedOrCancelledIsNoTapAndTheNextOneCounts() {
        var tap = FingerTap()
        tap.began(1, at: p, time: 0)
        tap.began(2, at: p, time: 0)
        tap.invalidate()
        _ = tap.ended(1, at: p, time: 0.1)
        #expect(tap.ended(2, at: p, time: 0.1) == nil)

        tap.began(1, at: p, time: 1)
        tap.began(2, at: p, time: 1)
        tap.cancelled(1)
        #expect(tap.ended(2, at: p, time: 1.1) == nil)

        tap.began(3, at: p, time: 2)
        tap.began(4, at: p, time: 2)
        _ = tap.ended(3, at: p, time: 2.1)
        #expect(tap.ended(4, at: p, time: 2.1) == 2)
    }

    @Test func oneFingerTapReportsOne() {
        var tap = FingerTap()
        tap.began(1, at: p, time: 0)
        #expect(tap.ended(1, at: p, time: 0.1) == 1, "the host ignores counts other than 2 and 3")
    }
}
