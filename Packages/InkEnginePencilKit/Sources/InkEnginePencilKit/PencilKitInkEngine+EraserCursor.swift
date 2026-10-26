import InkEngine
import UIKit

/// The eraser's reach (#116): a circle of the eraser's diameter under the tip while erasing and while the
/// Pencil (or pointer) hovers. Drawn in content space on the selection view, so it zooms with the page and
/// matches what `Tools` hit-tests.
extension PencilKitInkEngine {
    static let eraserCursorFade: CFTimeInterval = 0.15

    func setUpEraserCursor() {
        selection.eraser.fillColor = UIColor(white: 0.5, alpha: 0.12).cgColor
        selection.eraser.strokeColor = UIColor(white: 0.45, alpha: 0.85).cgColor
        selection.eraser.opacity = 0
        selection.view.layer.addSublayer(selection.eraser)
        input.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(eraserHover(_:))))
    }

    @objc private func eraserHover(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed:
            showEraserCursor(at: hover.location(in: input))
        default:
            hideEraserCursor()
        }
    }

    /// Follows the live eraser stroke; hides on lift.
    func trackEraserCursor(_ event: InkInputTracker.Event) {
        switch event {
        case let .began(stroke), let .updated(stroke):
            guard let last = stroke.displaySamples.last else { return }
            showEraserCursor(at: CGPoint(x: CGFloat(last.x), y: CGFloat(last.y)).applying(stroke.viewToPage.inverted()))
        case .ended, .cancelled:
            hideEraserCursor()
        }
    }

    /// Centers the circle on `center` (content space).
    func showEraserCursor(at center: CGPoint) {
        guard tool.tool == .eraser else { return hideEraserCursor() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let diameter = CGFloat(tool.width)
        let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        selection.eraser.path = CGPath(ellipseIn: rect, transform: nil)
        // The layer zooms with the page; keep the outline 1 pt on screen.
        selection.eraser.lineWidth = 1 / max(viewport.zoomScale, 0.01)
        selection.eraser.removeAnimation(forKey: "fade")
        selection.eraser.opacity = 1
    }

    func hideEraserCursor() {
        guard selection.eraser.opacity > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = selection.eraser.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = Self.eraserCursorFade
        selection.eraser.opacity = 0
        selection.eraser.add(fade, forKey: "fade")
    }
}
