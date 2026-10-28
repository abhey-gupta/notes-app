import CoreGraphics
import Foundation

/// The laser pointer's trail (#159): the tip's paths in content space, one per Pencil stroke. Fully bright
/// while the Pencil touches; on lift the whole trail fades over ``fadeDuration``. Touching again before it
/// is gone brings it back to full brightness and the new stroke adds to it; after that it starts empty.
/// Pure, so the timing is testable without Core Animation.
struct LaserTrail {
    /// Fade after lift.
    static let fadeDuration: TimeInterval = 0.7

    /// Paths drawn so far, oldest first.
    private(set) var strokes: [[CGPoint]] = []
    /// When the Pencil last lifted; `nil` while it touches.
    private(set) var liftedAt: TimeInterval?

    /// Nothing to draw (a tap leaves a single point, no line).
    var isEmpty: Bool {
        strokes.allSatisfy { $0.count < 2 }
    }

    /// Opacity at `now`: 1 while touching, falling linearly to 0 over ``fadeDuration`` after lift.
    func opacity(at now: TimeInterval) -> Float {
        guard let liftedAt else { return 1 }
        let elapsed = now - liftedAt
        return elapsed >= Self.fadeDuration ? 0 : Float(1 - max(elapsed, 0) / Self.fadeDuration)
    }

    /// Pencil down at `now`: a faded-out trail is dropped, a fading one is kept (bright again).
    mutating func begin(at now: TimeInterval) {
        if opacity(at: now) == 0 {
            strokes.removeAll()
        }
        liftedAt = nil
        strokes.append([])
    }

    /// Adds the tip to the current stroke; skips moves under a quarter point.
    mutating func append(_ point: CGPoint) {
        guard !strokes.isEmpty else { return }
        if let last = strokes[strokes.count - 1].last, hypot(point.x - last.x, point.y - last.y) < 0.25 {
            return
        }
        strokes[strokes.count - 1].append(point)
    }

    /// Pencil up at `now`: the fade starts.
    mutating func lift(at now: TimeInterval) {
        liftedAt = now
    }

    mutating func removeAll() {
        strokes.removeAll()
        liftedAt = nil
    }
}
