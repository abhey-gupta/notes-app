#if canImport(UIKit)
    import UIKit

    /// Zoom gestures: the engine's viewport says when a zoom is under way (``InkEngine/Viewport/isZooming``)
    /// and gets one settled viewport when it ends, so it can leave its canvases to the scroll view's
    /// transform until then and re-tile once (ARCHITECTURE.md §3, Zoom).
    extension CanvasHostView {
        /// A pinch, or the bounce back into the zoom range after one, is under way: the engine leaves its
        /// canvases alone (UIKit's zoom transform scales them with the paper) and re-tiles them once at the
        /// end. Pinching comes from the pinch recognizer (`CanvasScrollView.applyPinch` zooms when UIKit
        /// doesn't).
        var isZooming: Bool {
            isPinching || isSnapping || canvasScrollView.isZoomBouncing
        }

        @objc func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
            isPinching = pinch.state == .began || pinch.state == .changed
            if pinch.state == .began {
                snapHaptic.prepare()
            }
            settleZoom()
            if pinch.state == .ended {
                snapToFitWidth()
            }
        }

        /// Zoom at which the page spans the view edge to edge (what a pinch near it snaps to, #130).
        public var fillZoom: CGFloat {
            PageLayout.fillZoom(pageWidth: layout.pageSize.width, viewWidth: bounds.width)
        }

        /// Animates to `zoom` about the vertical center of the viewport, horizontally centered
        /// (edge to edge at ``fillZoom``). The engine re-tiles once when the animation ends.
        public func animateZoom(to zoom: CGFloat, duration: TimeInterval = 0.3) {
            let target = min(max(zoom, Self.minimumZoom), Self.maximumZoom)
            let z = canvasScrollView.zoomScale
            guard z > 0, abs(target - z) > 0.0005 else { return }
            let inset = canvasScrollView.contentInset
            let view = canvasScrollView.bounds
            let anchorY = (view.minY + inset.top + (view.height - inset.top - inset.bottom) / 2) / z
            isSnapping = true
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.canvasScrollView.zoomScale = target
                self.sizeContent()
                self.updateInsets()
                let inset = self.canvasScrollView.contentInset
                let maxY = max(self.canvasScrollView.contentSize.height + inset.bottom - view.height, -inset.top)
                let y = anchorY * target - inset.top - (view.height - inset.top - inset.bottom) / 2
                self.canvasScrollView.contentOffset = CGPoint(x: self.centeredOffsetX(), y: min(max(y, -inset.top), maxY))
                self.state.zoomScale = target
                self.viewportDidChange()
            } completion: { _ in
                self.isSnapping = false
                self.settleZoom()
            }
        }

        /// A pinch that ended with the page about as wide as the screen (within 5 % of ``fillZoom``)
        /// eases onto exactly that width with a light tap (#130). Not during the pinch (no magnet under
        /// the fingers) and not while UIKit bounces back from beyond the zoom range (far from fit width
        /// anyway). Runs on the next turn, after `UIScrollView`'s own end-of-pinch correction.
        func snapToFitWidth() {
            Task { @MainActor [weak self] in
                guard let self, !isPinching, !canvasScrollView.isZoomBouncing,
                      let target = PageLayout.snapZoom(canvasScrollView.zoomScale, fill: fillZoom),
                      target >= Self.minimumZoom, target <= Self.maximumZoom else { return }
                snapHaptic.impactOccurred()
                animateZoom(to: target)
            }
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
