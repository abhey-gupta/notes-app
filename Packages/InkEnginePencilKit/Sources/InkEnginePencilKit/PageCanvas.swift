import InkModel
import PencilKit
import UIKit

/// One pooled `PKCanvasView` and what it holds: the page it draws, the stroke IDs parallel to its
/// drawing, and whether PencilKit has drawn that page since it got it (the page's raster stays
/// underneath until then, so ink never blinks out when a canvas moves to a page).
@MainActor
final class PageCanvas {
    let view = AdapterCanvasView()
    /// The page this canvas draws, `nil` when free (hidden, in the pool).
    private(set) var page: PageID?
    /// Stroke IDs parallel to `view.drawing.strokes`.
    var ids: [StrokeID] = []
    /// The part of the page (page space) PencilKit has drawn: `nil` until the first render after the canvas
    /// got the page, the placement at the last `canvasViewDidFinishRendering` (or the 0.5 s cap) after a
    /// zoom change, and the current placement after a scroll (PencilKit draws scrolled-in tiles at once,
    /// cached ones without a callback). The page's raster covers everything else, so ink never blinks out
    /// when a canvas moves to a page or covers more after a zoom.
    var renderedRegion: CGRect?

    /// PencilKit has drawn the current page at least once.
    var hasRendered: Bool {
        renderedRegion != nil
    }

    /// The part of the page the canvas covers *and* has drawn (page space): where the raster can stay out.
    var drawnRegion: CGRect? {
        guard let renderedRegion, let placement else { return nil }
        let drawn = renderedRegion.intersection(placement.region)
        return drawn.isNull || drawn.isEmpty ? nil : drawn
    }

    /// A PencilKit stroke is in progress; the drawing can't be replaced until it ends.
    var isUsingTool = false
    /// The stroke in progress was cut short by a shape snap (#165): whatever PencilKit adds for it is
    /// dropped, never reported. Cleared when the next stroke begins.
    var discardsStroke = false
    var needsRebuild = false
    /// Where the canvas sits (`nil`: hidden).
    var placement: CanvasPlacement?
    /// Bumps whenever a render is awaited (page assignment, zoom change); a stale render cap checks it.
    private(set) var renderWait = 0

    /// Starts waiting for a render; returns the token a cap must still match.
    func awaitRender() -> Int {
        renderWait += 1
        return renderWait
    }

    init() {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.overrideUserInterfaceStyle = .light
        view.isScrollEnabled = false
        view.bouncesZoom = false
        view.contentInsetAdjustmentBehavior = .never
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        // Zoom is pinned to the viewport's (``PencilKitInkEngine/place(_:_:)`` sets min = max = zoom), so the
        // canvas has no pinch of its own and a pinch over it zooms the host scroll view (the whole page).
        view.minimumZoomScale = 1
        view.maximumZoomScale = 1
        view.isHidden = true
    }

    /// Takes `page` (or none); the page's raster shows until ``hasRendered``.
    func assign(_ page: PageID?) {
        self.page = page
        renderedRegion = nil
        needsRebuild = false
        placement = nil
        renderWait += 1
        view.isHidden = page == nil
    }
}
