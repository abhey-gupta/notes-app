#if canImport(UIKit)
    import UIKit

    /// A page as it is on screen right now (pages overview zoom, #124): its full frame, the part of it
    /// inside the host, and a snapshot view of that part.
    public struct PageCapture {
        /// The page's frame (may extend past the host).
        public let pageFrame: CGRect
        /// `pageFrame` clipped to the host: what the user can see, and what `snapshot` shows.
        public let visibleFrame: CGRect
        /// The visible part's pixels, as a view the size of `visibleFrame` whose contents stretch with
        /// its bounds (`UIView.resizableSnapshotView`, render-server backed: nothing is rasterized on
        /// the main thread).
        public let snapshot: UIView
    }

    public extension CanvasHostView {
        /// Snapshots page `index` as drawn (paper, template, ink, photos), nothing from the chrome.
        /// `afterScreenUpdates` waits for a pending layout/render (after a programmatic scroll). Frames
        /// are in `space`'s coordinates (`nil`: the window). `nil` when the page is off screen or the
        /// host has no window.
        func capturePage(_ index: Int, afterScreenUpdates: Bool, in space: UIView? = nil) -> PageCapture? {
            guard window != nil, layout.frames.indices.contains(index) else { return nil }
            let pageFrame = contentView.convert(layout.frame(at: index), to: self)
            let visible = pageFrame.intersection(bounds)
            guard !visible.isEmpty, visible.width >= 1, visible.height >= 1,
                  let snapshot = resizableSnapshotView(from: visible, afterScreenUpdates: afterScreenUpdates, withCapInsets: .zero)
            else { return nil }
            snapshot.isUserInteractionEnabled = false
            return PageCapture(pageFrame: convert(pageFrame, to: space), visibleFrame: convert(visible, to: space), snapshot: snapshot)
        }
    }
#endif
