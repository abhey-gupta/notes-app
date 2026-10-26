#if canImport(UIKit)
    import UIKit

    /// Scroll view callbacks: every scroll/zoom frame becomes one viewport (`viewportDidChange`); the end of
    /// a zoom settles it (`CanvasHostView+Zoom.swift`).
    extension CanvasHostView: UIScrollViewDelegate {
        public func viewForZooming(in _: UIScrollView) -> UIView? {
            contentView
        }

        public func scrollViewDidScroll(_: UIScrollView) {
            if isZooming {
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
            zoomDidEnd() // after a bounce back into range, or a snap to fit width
        }
    }

    public extension CanvasHostView {
        /// Page `index`'s frame on screen (window points, zoom applied); `nil` off-window or out of range.
        func windowFrame(ofPage index: Int) -> CGRect? {
            guard window != nil, layout.frames.indices.contains(index) else { return nil }
            return contentView.convert(layout.frame(at: index), to: nil)
        }
    }
#endif
