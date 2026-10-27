@testable import Canvas
import Testing

/// Finger taps count as commands only away from Pencil contact (#121).
struct PalmGuardTests {
    @Test func allowsTapsWithNoPencilAround() {
        #expect(PalmGuard().allowsTap(at: 0))
        #expect(PalmGuard().allowsTap(at: 1000))
    }

    @Test func blocksTapsWhilePencilTouches() {
        var palm = PalmGuard()
        palm.pencilBegan()
        #expect(!palm.allowsTap(at: 50))
        palm.pencilEnded(at: 51)
        #expect(!palm.allowsTap(at: 51.1), "palm right after the Pencil lifts")
        #expect(palm.allowsTap(at: 51.5))
    }

    @Test func waitsForEveryPencilTouch() {
        var palm = PalmGuard()
        palm.pencilBegan()
        palm.pencilBegan()
        palm.pencilEnded(at: 10)
        #expect(!palm.allowsTap(at: 20))
        palm.pencilEnded(at: 20)
        #expect(palm.allowsTap(at: 21))
    }

    @Test func allLiftedClearsAMissedPencilLift() {
        var palm = PalmGuard()
        palm.pencilBegan()
        palm.allLifted()
        #expect(palm.allowsTap(at: 5))
    }
}
