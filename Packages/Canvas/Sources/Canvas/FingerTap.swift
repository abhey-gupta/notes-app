import CoreGraphics
import Foundation

/// Spots a quick multi-finger tap in a stream of touches (#121), without taking part in gesture
/// recognition: a tap recognizer on the canvas scroll view, even a disabled one, slows its pan enough to
/// swallow a fast flick. A sequence runs from the first finger down to the last one up; it is a tap when
/// it ends within ``maxDuration`` and no finger strayed more than ``maxMovement`` points (a pinch or a
/// scroll moves them). ``invalidate()`` spoils the running sequence (a Pencil or palm in the mix).
/// Times are `UITouch.timestamp`s (seconds), points in window space.
struct FingerTap {
    /// First finger down to last finger up, at most.
    static let maxDuration: TimeInterval = 0.35
    /// How far a finger may drift and still tap.
    static let maxMovement: CGFloat = 12

    private var starts: [Int: CGPoint] = [:]
    private var active: Set<Int> = []
    private var began: TimeInterval = 0
    private var isSpoiled = false

    /// A finger came down.
    mutating func began(_ id: Int, at point: CGPoint, time: TimeInterval) {
        if active.isEmpty {
            starts = [:]
            began = time
            isSpoiled = false
        }
        starts[id] = point
        active.insert(id)
    }

    /// A finger moved.
    mutating func moved(_ id: Int, to point: CGPoint) {
        guard let start = starts[id] else { return }
        if hypot(point.x - start.x, point.y - start.y) > Self.maxMovement {
            isSpoiled = true
        }
    }

    /// A finger lifted. Returns how many fingers tapped once the last one is up and the sequence was a tap.
    mutating func ended(_ id: Int, at point: CGPoint, time: TimeInterval) -> Int? {
        moved(id, to: point)
        active.remove(id)
        guard active.isEmpty, !starts.isEmpty else { return nil }
        let fingers = starts.count
        starts = [:]
        guard !isSpoiled, time - began <= Self.maxDuration else { return nil }
        return fingers
    }

    /// A finger was cancelled (the system took the touch): no tap.
    mutating func cancelled(_ id: Int) {
        isSpoiled = true
        active.remove(id)
        if active.isEmpty {
            starts = [:]
        }
    }

    /// The running sequence can't be a tap.
    mutating func invalidate() {
        isSpoiled = true
    }
}
