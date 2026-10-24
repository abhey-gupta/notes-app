#if canImport(UIKit)
    import UIKit

    /// Zoom gestures: the engine's viewport says when a zoom is under way (``InkEngine/Viewport/isZooming``)
    /// and gets one settled viewport when it ends, so it can hold expensive re-rendering until then
    /// (ARCHITECTURE.md §3, Zoom).
    extension CanvasHostView {
        /// A pinch, or the bounce back into the zoom range after one, is under way. Pinching comes from the
        /// pinch recognizer: with the canvas under the fingers UIKit doesn't zoom (or report zooming) itself
        /// (`CanvasScrollView.applyPinch`).
        var isPinchActive: Bool {
            isPinching || canvasScrollView.isZoomBouncing
        }

        /// The engine holds its canvas: through the pinch and until the scroll view is at rest after it
        /// (``ZoomHold``). Settling mid-deceleration or mid-bounce left the ink behind the paper while
        /// PencilKit re-rendered at the new zoom.
        var isZooming: Bool {
            ZoomHold.holds(
                pinching: isPinching, zoomBouncing: canvasScrollView.isZoomBouncing, held: engineIsZooming,
                dragging: canvasScrollView.isDragging, decelerating: canvasScrollView.isDecelerating
            )
        }

        @objc func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
            isPinching = pinch.state == .began || pinch.state == .changed
            settleZoom()
        }

        /// Keeps the offset within the content's edges on every frame of a pinch, so the two-finger pan never
        /// rubber-bands past the top or bottom (nor sideways; a narrow page stays centered). Traced on a
        /// real iPad: when a zoom ends with the offset out of range, `UIScrollView` animates it back with a
        /// `UIView` animation that our scroll callbacks run inside, so the engine view and the canvas inherited
        /// the animation and glided while the paper (laid out with actions disabled) jumped: the ink drifted
        /// off the page for ~0.2 s and snapped back. Nothing reports that animation (`isDecelerating`,
        /// `isZoomBouncing` stay false), so it is prevented rather than waited out.
        func pinOffset() {
            let offset = canvasScrollView.contentOffset
            let inset = canvasScrollView.contentInset
            let z = canvasScrollView.zoomScale
            let pinned = PageLayout.pinnedOffset(
                offset,
                contentSize: CGSize(width: layout.contentSize.width * z, height: layout.contentSize.height * z),
                viewSize: bounds.size,
                insets: PageLayout.Insets(top: inset.top, left: inset.left, bottom: inset.bottom, right: inset.right)
            )
            if pinned != offset {
                canvasScrollView.contentOffset = pinned
            }
        }

        /// Once a zoom is over and the page has stopped moving, sends the engine a settled viewport (it
        /// re-renders at the final zoom). Checked again on the next turn in case UIKit flips `isZoomBouncing`
        /// or `isDecelerating` after its callbacks.
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
