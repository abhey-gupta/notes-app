/// When the engine must keep its canvas held at the pre-zoom rendering (`Viewport.isZooming`,
/// ARCHITECTURE.md §3, Zoom): through the pinch, the zoom bounce, and any scroll the release starts.
///
/// A pinch's release usually moves the page: the two-finger pan's velocity decelerates, an offset dragged
/// past the top or bottom rubber-bands back, a zoom past the range bounces. Settling the canvas sets its
/// `zoomScale`, which PencilKit re-renders over several frames, so settling while the page is still
/// moving leaves the ink behind the paper until the render lands (real iPad: ink drifted vertically on
/// release, then snapped back). The hold ends only once the scroll view is at rest.
enum ZoomHold {
    /// Whether the engine keeps its canvas held this frame.
    /// - Parameters:
    ///   - pinching: the pinch recognizer is active.
    ///   - zoomBouncing: `UIScrollView.isZoomBouncing`.
    ///   - held: the engine is holding its canvas (the last viewport it got was zooming).
    ///   - dragging: `UIScrollView.isDragging` (a finger still moves the page after the pinch).
    ///   - decelerating: `UIScrollView.isDecelerating` (deceleration or a rubber-band back into range).
    static func holds(pinching: Bool, zoomBouncing: Bool, held: Bool, dragging: Bool, decelerating: Bool) -> Bool {
        pinching || zoomBouncing || (held && (dragging || decelerating))
    }
}
