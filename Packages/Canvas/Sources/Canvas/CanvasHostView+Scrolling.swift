#if canImport(UIKit)
    import UIKit

    /// Scroll view callbacks: every scroll/zoom frame becomes one viewport (`viewportDidChange`); the end of
    /// a zoom, a drag or a deceleration may settle a held zoom (`CanvasHostView+Zoom.swift`).
    extension CanvasHostView: UIScrollViewDelegate {
        public func viewForZooming(in _: UIScrollView) -> UIView? {
            contentView
        }

        public func scrollViewDidScroll(_: UIScrollView) {
            if isPinchActive {
                pinHorizontalOffset()
            }
            viewportDidChange()
        }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateInsets()
            pinHorizontalOffset()
            state.zoomScale = scrollView.zoomScale
            viewportDidChange()
        }

        public func scrollViewWillBeginDragging(_: UIScrollView) {
            delegate?.canvasHostWillBeginNavigating(self)
        }

        public func scrollViewWillBeginZooming(_: UIScrollView, with _: UIView?) {
            delegate?.canvasHostWillBeginNavigating(self)
        }

        public func scrollViewDidEndZooming(_: UIScrollView, with _: UIView?, atScale _: CGFloat) {
            settleZoom() // after a bounce back into range
        }

        public func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                settleZoom() // the finger left after the pinch without a flick
            }
        }

        public func scrollViewDidEndDecelerating(_: UIScrollView) {
            settleZoom() // after the release's deceleration or rubber band
        }
    }
#endif
