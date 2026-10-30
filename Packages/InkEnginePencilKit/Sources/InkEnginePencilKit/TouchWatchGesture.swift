import InkEngine
import UIKit

/// Watches a drawing touch without taking part in recognition (hold to snap, #165; ink running onto the next
/// page, #163): it never recognizes, delays or cancels anything, so PencilKit and the input view get every
/// touch as before. Follows the first touch ``onBegan`` takes (one that draws: not a resting palm) until it
/// lifts.
@MainActor
final class TouchWatchGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// A touch went down while none is followed; `true` follows it.
    var onBegan: ((TouchRecord) -> Bool)?
    var onMoved: (([TouchRecord]) -> Void)?
    /// `true` when the touch was cancelled.
    var onEnded: ((Bool) -> Void)?
    private var touch: UITouch?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
        guard touch == nil, let view else { return }
        touch = touches.first { onBegan?(TouchRecord($0, in: view)) == true }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch), let view else { return }
        let id = TouchID(touch)
        let coalesced = event.coalescedTouches(for: touch) ?? [touch]
        onMoved?(coalesced.map { TouchRecord($0, id: id, in: view) })
    }

    override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        onEnded?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        onEnded?(true)
    }

    override func reset() {
        super.reset()
        if touch != nil {
            touch = nil
            onEnded?(true)
        }
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}
