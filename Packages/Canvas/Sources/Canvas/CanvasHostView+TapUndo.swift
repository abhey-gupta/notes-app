#if canImport(UIKit)
    import UIKit

    /// Finger taps on the canvas (#121): two fingers undo, three redo, while
    /// ``CanvasHostView/allowsTapUndo``. A tap fails as soon as its fingers move, so pinch and scroll keep
    /// working; fingers touching down during or just after Pencil contact are ignored (``PalmGuard``), and
    /// so are taps while fingers ink ("draw with finger" before a Pencil is seen). No feedback: the ink
    /// changing is the feedback.
    ///
    /// While on, the system's three-finger editing gestures are off for the canvas: their tap pops the
    /// undo bar, which would land on every redo. ⌘Z keeps working.
    @MainActor
    final class TapUndoGestures: NSObject, UIGestureRecognizerDelegate {
        let undo = UITapGestureRecognizer()
        let redo = UITapGestureRecognizer()
        /// Whether a touch at a timestamp may join a tap (the touch observer's ``PalmGuard``).
        var allowsTouch: (TimeInterval) -> Bool = { _ in true }

        init(target: CanvasHostView) {
            super.init()
            for (recognizer, fingers, action) in [
                (undo, 2, #selector(CanvasHostView.handleUndoTap)), (redo, 3, #selector(CanvasHostView.handleRedoTap)),
            ] {
                recognizer.numberOfTouchesRequired = fingers
                recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                recognizer.delegate = self
                recognizer.addTarget(target, action: action)
            }
        }

        var isEnabled: Bool {
            get { undo.isEnabled }
            set {
                undo.isEnabled = newValue
                redo.isEnabled = newValue
            }
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            allowsTouch(touch.timestamp)
        }
    }

    extension CanvasHostView {
        func installTapUndo() {
            tapUndo.allowsTouch = { [weak self] time in self?.touchObserver.palmGuard.allowsTap(at: time) ?? false }
            canvasScrollView.addGestureRecognizer(tapUndo.undo)
            canvasScrollView.addGestureRecognizer(tapUndo.redo)
        }

        @objc func handleUndoTap() {
            delegate?.canvasHostDidRequestUndo(self)
        }

        @objc func handleRedoTap() {
            delegate?.canvasHostDidRequestRedo(self)
        }
    }
#endif
