#if canImport(UIKit)
    import UIKit

    /// Live resize (split view, #175): the host's frame goes through many sizes in a row (panes sliding in
    /// or out, the divider under a finger). Re-fitting the page on each of those frames would re-tile ink
    /// 120 times a second, so the canvas holds still instead, under a snapshot of what it showed that
    /// follows the frame the way the page will land when it refits: the fitted width (or the same zoom),
    /// the same content under the top margin, centered. At the end the canvas refits once and the
    /// snapshot fades into it.
    public extension CanvasHostView {
        internal struct LiveResize {
            /// What the host showed; `nil` when there was nothing on screen to capture.
            let snapshot: UIView?
            /// At the start: view size, zoom, content offset, top inset, and whether the page was fitted.
            let size: CGSize
            let zoom: CGFloat
            let offset: CGPoint
            let topInset: CGFloat
            let wasFitted: Bool
        }

        /// A live resize holds the canvas.
        var isLiveResizing: Bool {
            liveResize != nil
        }

        /// The frame is about to go through several sizes: hold the canvas (input included) under a
        /// snapshot until ``endLiveResize()``. Repeated calls are absorbed.
        func beginLiveResize() {
            guard liveResize == nil, lastBoundsSize != .zero else { return }
            cancelSideGrabForResize()
            settlingSnapshot?.removeFromSuperview()
            settlingSnapshot = nil
            let z = scrollView.zoomScale
            var snapshot: UIView?
            if window != nil, let view = resizableSnapshotView(from: bounds, afterScreenUpdates: false, withCapInsets: .zero) {
                view.isUserInteractionEnabled = false
                view.layer.anchorPoint = .zero
                view.frame = bounds
                addSubview(view)
                snapshot = view
            }
            liveResize = LiveResize(
                snapshot: snapshot, size: bounds.size, zoom: z, offset: scrollView.contentOffset,
                topInset: scrollView.contentInset.top, wasFitted: abs(z - fitZoom) < 0.001
            )
            clipsToBounds = true
            scrollView.autoresizingMask = []
            if snapshot != nil {
                scrollView.alpha = 0
            }
        }

        /// The frame has settled: the canvas refits to it, then the snapshot fades into the live canvas once
        /// the engine has drawn the new zoom.
        func endLiveResize() {
            guard let live = liveResize else { return }
            liveResize = nil
            clipsToBounds = false
            scrollView.frame = bounds
            scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrollView.alpha = 1
            let size = bounds.size
            if size.width > 0, size.height > 0 {
                resize(from: lastBoundsSize, to: size, refit: live.wasFitted)
                lastBoundsSize = size
            }
            guard let snapshot = live.snapshot else { return }
            settlingSnapshot = snapshot
            Task { @MainActor [weak self, weak snapshot] in
                // Two frames for the engine to draw the refit page.
                try? await Task.sleep(for: .milliseconds(34))
                guard let snapshot else { return }
                UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    snapshot.alpha = 0
                } completion: { _ in
                    snapshot.removeFromSuperview()
                    if self?.settlingSnapshot === snapshot {
                        self?.settlingSnapshot = nil
                    }
                }
            }
        }

        /// Places the snapshot for the current bounds (from `layoutSubviews` while held).
        internal func layoutLiveResize() {
            guard let live = liveResize, let snapshot = live.snapshot else { return }
            let (scale, origin) = liveResizeMapping(live, to: bounds.size)
            UIView.performWithoutAnimation {
                snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
                snapshot.layer.position = origin
            }
        }

        /// Where the content shown at the start lands once the canvas refits to `size` (as ``resize(from:to:refit:)``
        /// does): its scale, and where the snapshot's top-left goes. The content point under the top inset
        /// stays under it; the content is centered across.
        private func liveResizeMapping(_ live: LiveResize, to size: CGSize) -> (scale: CGFloat, origin: CGPoint) {
            let zoom = live.wasFitted
                ? Self.fitZoom(pageWidth: layout.pageSize.width, viewWidth: size.width, desk: fitDesk)
                : live.zoom
            let scale = zoom / live.zoom
            let offsetX = (layout.contentSize.width * zoom - size.width) / 2
            let topInset = safeAreaInsets.top + margins.top
            return (scale, CGPoint(x: scale * live.offset.x - offsetX, y: topInset - scale * live.topInset))
        }
    }
#endif
