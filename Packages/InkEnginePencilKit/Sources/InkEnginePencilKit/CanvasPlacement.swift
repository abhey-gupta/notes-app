import CoreGraphics
import InkModel

/// Where the `PKCanvasView` sits for one viewport (ARCHITECTURE.md §3, Zoom).
///
/// The canvas draws `region` (page space) at `renderZoom` (its pinned `zoomScale`) and is scaled by
/// `scale = zoom / renderZoom` about its center to the viewport's zoom. Settled, `renderZoom == zoom` and
/// the canvas is exactly the page's visible rect. During a zoom gesture `renderZoom` and `region` stay
/// what the canvas last rendered and only `center` and `scale` follow the pinch: plain Core Animation
/// geometry, composited in the same transaction as the paper, with nothing for PencilKit to redraw.
///
/// Page point `p` lands at `pageOrigin + zoom · p` in view space, like the paper (``viewPoint(_:)``).
struct CanvasPlacement: Equatable {
    /// `PKCanvasView.zoomScale` (min = max = this).
    var renderZoom: CGFloat
    /// Canvas content size: the page at `renderZoom`.
    var contentSize: CGSize
    /// Canvas bounds; `origin` is its `contentOffset`.
    var bounds: CGRect
    /// Canvas center in engine view space.
    var center: CGPoint
    /// Uniform scale transform (1 when settled).
    var scale: CGFloat

    /// Settled: the canvas is `visible` (the page's visible rect, view space) at the viewport zoom.
    static func settled(visible: CGRect, pageRect: CGRect, zoom: CGFloat, pageSize: CGSize) -> CanvasPlacement {
        CanvasPlacement(
            renderZoom: zoom,
            contentSize: CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom),
            bounds: CGRect(
                origin: CGPoint(x: visible.minX - pageRect.minX, y: visible.minY - pageRect.minY),
                size: visible.size
            ),
            center: CGPoint(x: visible.midX, y: visible.midY),
            scale: 1
        )
    }

    /// Mid-zoom: the canvas still draws `region` (page space) at `renderZoom`, scaled to `zoom` with the
    /// page's top-left at `pageOrigin` (view space).
    static func scaled(
        region: CGRect, renderZoom: CGFloat, pageOrigin: CGPoint, zoom: CGFloat, pageSize: CGSize
    ) -> CanvasPlacement {
        CanvasPlacement(
            renderZoom: renderZoom,
            contentSize: CGSize(width: pageSize.width * renderZoom, height: pageSize.height * renderZoom),
            bounds: CGRect(
                x: region.minX * renderZoom, y: region.minY * renderZoom,
                width: region.width * renderZoom, height: region.height * renderZoom
            ),
            center: CGPoint(x: pageOrigin.x + region.midX * zoom, y: pageOrigin.y + region.midY * zoom),
            scale: zoom / renderZoom
        )
    }

    /// The page-space rect the canvas shows.
    var region: CGRect {
        CGRect(
            x: bounds.minX / renderZoom, y: bounds.minY / renderZoom,
            width: bounds.width / renderZoom, height: bounds.height / renderZoom
        )
    }

    /// Where page point `p` appears in engine view space: canvas content `p · renderZoom`, through the
    /// bounds and the scale about the center (UIKit's own view geometry).
    func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + scale * (p.x * renderZoom - bounds.midX),
            y: center.y + scale * (p.y * renderZoom - bounds.midY)
        )
    }

    /// The canvas's frame in engine view space (its bounds scaled about its center).
    var frame: CGRect {
        CGRect(
            x: center.x - bounds.width * scale / 2, y: center.y - bounds.height * scale / 2,
            width: bounds.width * scale, height: bounds.height * scale
        )
    }
}

/// The canvas's zoom bookkeeping (``PencilKitInkEngine/layoutCanvas()``).
struct CanvasZoomState {
    /// Set while a zoom gesture runs and until the canvas has redrawn after it.
    var freeze: ZoomFreeze?
    /// The page the canvas was last placed on (`nil`: hidden).
    var placedPage: PageID?
    /// Invalidates a pending settle timeout.
    var settleToken = 0
}

/// The canvas's zoom state while a pinch is under way and just after.
struct ZoomFreeze {
    /// The active page the canvas was on when the zoom began.
    var page: PageID
    /// What the canvas had rendered when the zoom began (page space) and at which `zoomScale`.
    var region: CGRect
    var renderZoom: CGFloat
    /// The zoom ended and the canvas is re-rendering at the final zoom; the page raster still fills in
    /// around `region` until `canvasViewDidFinishRendering`.
    var settling = false
}
