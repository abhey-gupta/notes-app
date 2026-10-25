import CoreGraphics
import InkModel

/// Where a page's `PKCanvasView` sits in the engine view (ARCHITECTURE.md §3, Zoom).
///
/// The engine view lives inside the host's zoom view, in content space (unzoomed points): UIKit's one
/// zoom transform scales paper and ink together, every frame of a pinch, bounce or fling. For crisp ink
/// the canvas renders at `zoom` (its pinned `zoomScale`, so PencilKit draws at screen resolution) and
/// is scaled back by `1 / zoom`, so in content space it covers exactly `region` of the page: page point
/// `p` lands at `pageOrigin + p`, where the paper puts it (``contentPoint(_:)``). Only the visible
/// part of the page gets a canvas (never a Metal layer the size of a page at 4×); it is re-placed on
/// every scroll frame and left alone while a zoom is under way.
struct CanvasPlacement: Equatable {
    /// `PKCanvasView.zoomScale` (min = max = this): the viewport zoom when placed.
    var zoom: CGFloat
    /// Page frame in content space.
    var pageFrame: CGRect
    /// The part of the page the canvas covers (page space).
    var region: CGRect

    /// The canvas for the part of `pageFrame` inside `visibleRect` (both content space), `nil` when none.
    static func visible(pageFrame: CGRect, in visibleRect: CGRect, zoom: CGFloat) -> CanvasPlacement? {
        guard zoom > 0 else { return nil }
        let shown = pageFrame.intersection(visibleRect)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return nil }
        return CanvasPlacement(
            zoom: zoom, pageFrame: pageFrame,
            region: shown.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY)
        )
    }

    /// Canvas content size: the page at `zoom`.
    var contentSize: CGSize {
        CGSize(width: pageFrame.width * zoom, height: pageFrame.height * zoom)
    }

    /// Canvas bounds; `origin` is its `contentOffset`.
    var bounds: CGRect {
        CGRect(x: region.minX * zoom, y: region.minY * zoom, width: region.width * zoom, height: region.height * zoom)
    }

    /// Canvas center in content space.
    var center: CGPoint {
        center(contentOffset: bounds.origin)
    }

    /// Canvas center in content space for the `contentOffset` the canvas actually took: `UIScrollView`
    /// pixel-aligns offsets (20.4 → 20.5 at 2×), and the center must follow or the ink lands a fraction
    /// of a point off the paper.
    func center(contentOffset: CGPoint) -> CGPoint {
        CGPoint(
            x: pageFrame.minX + (contentOffset.x + bounds.width / 2) * scale,
            y: pageFrame.minY + (contentOffset.y + bounds.height / 2) * scale
        )
    }

    /// Uniform scale transform back to content space.
    var scale: CGFloat {
        1 / zoom
    }

    /// Where page point `p` appears in content space: canvas content `p · zoom`, through the bounds and
    /// the scale about the center (UIKit's own view geometry). Equals `pageFrame.origin + p`.
    func contentPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + scale * (p.x * zoom - bounds.midX),
            y: center.y + scale * (p.y * zoom - bounds.midY)
        )
    }

    /// The canvas's frame in content space (its bounds scaled about its center): `region` on the page.
    var frame: CGRect {
        CGRect(
            x: center.x - bounds.width * scale / 2, y: center.y - bounds.height * scale / 2,
            width: bounds.width * scale, height: bounds.height * scale
        )
    }
}
