#if canImport(UIKit)
    import UIKit

    /// Zoom gestures: the engine's viewport says when a zoom is under way (``InkEngine/Viewport/isZooming``)
    /// and gets one settled viewport when it ends, so it can hold expensive re-rendering until then
    /// (ARCHITECTURE.md §3, Zoom).
    extension CanvasHostView {
        /// A pinch, or the bounce back into the zoom range after one, is under way. Pinching comes from the
        /// pinch recognizer: with the canvas under the fingers UIKit doesn't zoom (or report zooming) itself
        /// (`CanvasScrollView.applyPinch`).
        var isZooming: Bool {
            isPinching || canvasScrollView.isZoomBouncing
        }

        @objc func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
            isPinching = pinch.state == .began || pinch.state == .changed
            settleZoom()
        }

        /// Keeps a zoom horizontally symmetric: no horizontal rubber-banding while pinching, so nothing
        /// snaps sideways (and the canvas re-renders mid-snap) on release. A page narrower than the view
        /// stays centered; a wider one stays within its edges.
        func pinHorizontalOffset() {
            let x = canvasScrollView.contentOffset.x
            let inset = canvasScrollView.contentInset
            let pinned = PageLayout.pinnedOffsetX(
                x, contentWidth: layout.contentSize.width * canvasScrollView.zoomScale,
                viewWidth: bounds.width, leftInset: inset.left, rightInset: inset.right
            )
            if pinned != x {
                canvasScrollView.contentOffset.x = pinned
            }
        }

        /// Once a zoom is over, sends the engine a settled viewport (it re-renders at the final zoom). Checked
        /// again on the next turn in case UIKit flips `isZoomBouncing` after its callbacks.
        func settleZoom() {
            guard engineIsZooming else { return }
            if !isZooming {
                viewportDidChange()
            } else {
                Task { @MainActor [weak self] in
                    guard let self, engineIsZooming, !isZooming else { return }
                    viewportDidChange()
                }
            }
        }
    }
#endif
