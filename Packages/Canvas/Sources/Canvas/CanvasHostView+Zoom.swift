#if canImport(UIKit)
    import UIKit

    /// Zoom gestures: the engine's viewport says when a zoom is under way (``InkEngine/Viewport/isZooming``)
    /// and gets one settled viewport when it ends, so it can leave its canvases to the scroll view's
    /// transform until then and re-tile once (ARCHITECTURE.md §3, Zoom).
    extension CanvasHostView {
        /// A pinch, the bounce back into the zoom range after one, or the snap to fit width is under way:
        /// the engine leaves its canvases alone (UIKit's zoom transform scales them with the paper) and
        /// re-tiles them once at the end. Pinching comes from the pinch recognizer
        /// (`CanvasScrollView.applyPinch` zooms when UIKit doesn't).
        var isZooming: Bool {
            isPinching || canvasScrollView.isZoomBouncing || zoomSnapTarget != nil
        }

        @objc func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
            isPinching = pinch.state == .began || pinch.state == .changed
            if pinch.state == .began {
                zoomSnapTarget = nil
            } else if pinch.state == .ended {
                snapToFitWidth()
            }
            settleZoom()
        }

        /// The zoom at which the page is as wide as the view less its side margins.
        var fitWidthZoom: CGFloat {
            let width = bounds.width - margins.left - margins.right
            guard layout.pageSize.width > 0, width > 0 else { return canvasScrollView.zoomScale }
            return min(max(width / layout.pageSize.width, Self.minimumZoom), Self.maximumZoom)
        }

        /// A pinch that ends near fit width eases the rest of the way there with a light tap (#130). The
        /// engine treats the animation as part of the zoom (`isZooming`) and settles when it lands.
        func snapToFitWidth() {
            let scrollView = canvasScrollView
            guard !scrollView.isZoomBouncing,
                  let target = PageLayout.snappedZoom(scrollView.zoomScale, fit: fitWidthZoom) else { return }
            zoomSnapTarget = target
            UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred()
            scrollView.setZoomScale(target, animated: true)
        }

        /// The snap landed (UIKit also reports the pinch's own end, before the animation): stop zooming.
        func zoomDidEnd() {
            if let target = zoomSnapTarget, abs(canvasScrollView.zoomScale - target) < 0.0001 {
                zoomSnapTarget = nil
            }
            settleZoom()
        }

        /// Keeps a zoom horizontally symmetric: no horizontal rubber-banding while pinching, so a page
        /// narrower than the view stays centered and a wider one stays within its edges. Vertical
        /// rubber-banding is left to UIKit (ink and paper share its transform, so nothing can drift).
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

        /// Once a zoom is over, sends the engine a settled viewport (it re-tiles at the final zoom). Checked
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
