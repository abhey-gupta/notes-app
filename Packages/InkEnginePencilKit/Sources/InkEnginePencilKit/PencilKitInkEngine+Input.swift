import InkEngine
import InkModel
import UIKit

/// Eraser and lasso input: the shared `InkInputView` (content-sized, above the canvases) reports samples in
/// page space; the engine forwards them and draws nothing (`Tools` resolves erasing, ARCHITECTURE.md §6).
extension PencilKitInkEngine: InkInputViewDelegate {
    public func inkInputView(_: InkInputView, targetAt point: CGPoint) -> InkInputTarget? {
        // The input view is content-sized: `point` is in content space, page space is a translation away.
        guard let page = viewport.pages.first(where: { $0.frame.contains(point) }) else { return nil }
        return InkInputTarget(page: page.id, viewToPage: CGAffineTransform(translationX: -page.frame.minX, y: -page.frame.minY))
    }

    public func inkInputView(_: InkInputView, didProduce event: InkInputTracker.Event) {
        if tool.tool == .lasso {
            drawLasso(event)
        }
        switch event {
        case let .began(stroke):
            if stroke.device == .pencil {
                pencilSeen()
            }
            eraserProgress = (stroke.touch, 0)
            delegate?.engineDidBeginStroke(self)
            emitEraser(stroke)
        case let .updated(stroke):
            emitEraser(stroke)
        case let .ended(stroke):
            emitEraser(stroke)
            if tool.tool == .lasso {
                delegate?.engine(self, didReceiveLasso: stroke.samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }, to: stroke.page)
            }
        case .cancelled:
            break
        }
    }

    private func emitEraser(_ stroke: LiveStroke) {
        guard tool.tool == .eraser, let progress = eraserProgress, progress.touch == stroke.touch,
              stroke.samples.count > progress.emitted else { return }
        eraserProgress = (stroke.touch, stroke.samples.count)
        delegate?.engine(self, didReceiveEraser: Array(stroke.samples[progress.emitted...]), to: stroke.page)
    }
}
