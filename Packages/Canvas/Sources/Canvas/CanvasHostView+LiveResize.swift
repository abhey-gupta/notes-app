#if canImport(UIKit)
    import UIKit

    /// Live resize (split view, #175): the host's frame goes through many sizes in a row (panes sliding in
    /// or out, the divider under a finger). Re-fitting the page on each of those frames would re-tile ink
    /// 120 times a second, so the canvas keeps its zoom instead and a transform does the sizing: the scroll
    /// view's bounds grow or shrink to what the frame shows at the start zoom, and it's scaled onto the
    /// frame the way the page will land when it refits: the fitted width, or a zoomed page scaled with the
    /// view's width (it keeps its share of the view), the same content under the top margin. Page that
    /// comes into view is drawn live (the engine tiles only what's new, at the zoom it has); input is off
    /// meanwhile. At the end the canvas refits once, under a snapshot that fades into it.
    public extension CanvasHostView {
        internal struct LiveResize {
            /// At the start: view size, zoom, content offset, insets, and whether the page was fitted.
            let size: CGSize
            let zoom: CGFloat
            let offset: CGPoint
            let insets: UIEdgeInsets
            let wasFitted: Bool
        }

        /// A live resize holds the canvas.
        var isLiveResizing: Bool {
            liveResize != nil
        }

        /// Insets wide enough for any offset the scaled scroll view needs, so UIKit never clamps it.
        private static let liveResizeInset: CGFloat = 100_000

        /// The frame is about to go through several sizes: the canvas keeps its zoom (input off) and a
        /// transform sizes it until ``endLiveResize()``. Repeated calls are absorbed.
        func beginLiveResize() {
            guard liveResize == nil, lastBoundsSize != .zero else { return }
            cancelSideGrabForResize()
            settlingSnapshot?.removeFromSuperview()
            settlingSnapshot = nil
            let z = scrollView.zoomScale
            liveResize = LiveResize(
                size: bounds.size, zoom: z, offset: scrollView.contentOffset, insets: scrollView.contentInset,
                wasFitted: abs(z - fitZoom) < 0.001
            )
            clipsToBounds = true
            scrollView.autoresizingMask = []
            scrollView.isUserInteractionEnabled = false
            scrollView.layer.anchorPoint = .zero
            let inset = Self.liveResizeInset
            scrollView.contentInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
            layoutLiveResize()
        }

        /// The frame has settled: the canvas refits to it under a snapshot of what it showed, which fades into
        /// the live canvas once the engine has drawn the new zoom.
        func endLiveResize() {
            guard let live = liveResize else { return }
            let snapshot = window != nil ? resizableSnapshotView(from: bounds, afterScreenUpdates: false, withCapInsets: .zero) : nil
            liveResize = nil
            scrollView.transform = .identity
            scrollView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            scrollView.frame = bounds
            scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrollView.isUserInteractionEnabled = true
            // Back where it started (the refit anchors on the content at the top of the viewport).
            scrollView.contentInset = live.insets
            scrollView.contentOffset = live.offset
            let size = bounds.size
            if size.width > 0, size.height > 0 {
                if live.wasFitted {
                    resize(from: lastBoundsSize, to: size, refit: true)
                } else {
                    fitZoom = Self.fitZoom(pageWidth: layout.pageSize.width, viewWidth: size.width, desk: fitDesk)
                    let target = liveResizeTarget(live, to: size)
                    setZoom(target.zoom)
                    updateInsets()
                    scrollView.contentOffset = target.offset
                    viewportDidChange()
                }
                lastBoundsSize = size
            }
            guard let snapshot else {
                clipsToBounds = false
                return
            }
            snapshot.isUserInteractionEnabled = false
            snapshot.frame = bounds
            addSubview(snapshot)
            // Clipped until the snapshot is gone (an exact fit, but the host's frame may still be settling).
            settlingSnapshot = snapshot
            Task { @MainActor [weak self, weak snapshot] in
                // Two frames for the engine to draw the refit page.
                try? await Task.sleep(for: .milliseconds(34))
                guard let snapshot else { return }
                UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    snapshot.alpha = 0
                } completion: { _ in
                    snapshot.removeFromSuperview()
                    guard let self, self.settlingSnapshot === snapshot else { return }
                    self.settlingSnapshot = nil
                    if self.liveResize == nil {
                        self.clipsToBounds = false
                    }
                }
            }
        }

        /// Sizes and places the scroll view for the current bounds (from `layoutSubviews` while held): at
        /// the start zoom, its bounds cover what the frame shows once refit, scaled onto the frame. Moving
        /// its bounds is a scroll (the engine gets the wider viewport and tiles what's new).
        internal func layoutLiveResize() {
            guard let live = liveResize else { return }
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let target = liveResizeTarget(live, to: size)
            let scale = target.zoom / live.zoom
            let held = CGRect(
                x: target.offset.x / scale, y: target.offset.y / scale, width: size.width / scale, height: size.height / scale
            )
            UIView.performWithoutAnimation {
                if scrollView.bounds != held {
                    scrollView.bounds = held
                }
                scrollView.transform = CGAffineTransform(scaleX: scale, y: scale)
                scrollView.layer.position = .zero
            }
        }

        /// The zoom and content offset at `size`: a fitted page fits it and centers; a zoomed one scales with
        /// the width and keeps the content point at the top-left of the viewport there (within the content).
        /// The content point under the top inset stays under it.
        private func liveResizeTarget(_ live: LiveResize, to size: CGSize) -> (zoom: CGFloat, offset: CGPoint) {
            let content = layout.contentSize
            let zoom = live.wasFitted
                ? Self.fitZoom(pageWidth: layout.pageSize.width, viewWidth: size.width, desk: fitDesk)
                : min(max(live.zoom * size.width / live.size.width, Self.minimumZoom), Self.maximumZoom)
            let scale = zoom / live.zoom
            let width = content.width * zoom
            let left = PageLayout.sideInset(contentWidth: width, viewWidth: size.width, margin: margins.left)
            let right = PageLayout.sideInset(contentWidth: width, viewWidth: size.width, margin: margins.right)
            let x = live.wasFitted
                ? (width - size.width) / 2
                : min(max(scale * live.offset.x, -left), width + right - size.width)
            let topInset = safeAreaInsets.top + margins.top
            return (zoom, CGPoint(x: x, y: scale * (live.offset.y + live.insets.top) - topInset))
        }
    }
#endif
