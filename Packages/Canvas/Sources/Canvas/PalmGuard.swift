import Foundation

/// When a finger tap on the canvas counts as a command (#121): never while a Pencil touches the glass,
/// nor for ``quiet`` seconds after it lifts, so a palm landing mid-writing doesn't undo a stroke.
/// Times are `UITouch.timestamp`s (system uptime, seconds).
struct PalmGuard {
    /// Seconds after the Pencil lifts before a tap counts.
    static let quiet: TimeInterval = 0.3

    private var pencils = 0
    private var lastLift = -TimeInterval.infinity

    mutating func pencilBegan() {
        pencils += 1
    }

    mutating func pencilEnded(at time: TimeInterval) {
        pencils = max(pencils - 1, 0)
        lastLift = max(lastLift, time)
    }

    /// Every touch is gone (a missed Pencil lift can't block taps for good).
    mutating func allLifted() {
        pencils = 0
    }

    /// Whether a finger touching down at `time` may be part of a command tap.
    func allowsTap(at time: TimeInterval) -> Bool {
        pencils == 0 && time - lastLift >= Self.quiet
    }
}
