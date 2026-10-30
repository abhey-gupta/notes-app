#if canImport(UIKit)
    import InkEngine
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

        public func scrollViewDidEndZooming(_: UIScrollView, with _: UIView?, atScale _: CGFloat) {
            settleZoom() // after a bounce back into range
        }
    }

    public extension CanvasHostView {
        /// Scrolls so page `index`'s top sits under the top margin.
        func scrollToPage(_ index: Int, animated: Bool) {
            guard layout.frames.indices.contains(index) else { return }
            let z = scrollView.zoomScale
            let inset = scrollView.contentInset
            let maxY = max(scrollView.contentSize.height + inset.bottom - scrollView.bounds.height, -inset.top)
            let y = min(layout.frame(at: index).minY * z - inset.top, maxY)
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: animated)
        }

        /// Scroll offset and zoom in content terms (tests, state restoration).
        var viewport: Viewport {
            makeViewport()
        }
    }
#endif
