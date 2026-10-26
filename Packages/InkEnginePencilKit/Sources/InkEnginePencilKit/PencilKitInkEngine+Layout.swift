import InkEngine
import InkModel
import UIKit

extension PencilKitInkEngine {
    /// The visible content rect (content space).
    var visibleRect: CGRect {
        let z = max(viewport.zoomScale, 0.0001)
        return CGRect(
            x: viewport.contentOffset.x / z, y: viewport.contentOffset.y / z,
            width: viewport.size.width / z, height: viewport.size.height / z
        )
    }

    /// Gives the visible pages canvases and places each over the visible part of its page.
    ///
    /// Left alone while a zoom is under way (``InkEngine/Viewport/isZooming``): the host's zoom view scales
    /// the canvases with the paper, and setting `zoomScale` every frame would make PencilKit re-tile on the
    /// GPU each frame. Once the zoom ends every canvas takes the final zoom once (same geometry on screen,
    /// finer tiles); scrolling at one zoom only moves bounds and centers, which is plain view geometry.
    func layoutCanvases() {
        guard !viewport.isZooming else { return }
        let visible = visibleRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let wanted = viewport.pages
            .filter { snapshots[$0.id] != nil && $0.frame.intersects(visible) }
            .sorted { Self.distance(center, $0.frame) < Self.distance(center, $1.frame) }
            .prefix(maximumCanvases)
        let wantedIDs = Set(wanted.map(\.id))
        // A canvas mid-stroke keeps its page (even off screen), so the stroke commits where it began.
        for canvas in canvases where !canvas.isUsingTool {
            if let page = canvas.page, !wantedIDs.contains(page) {
                release(canvas)
            }
        }
        for page in wanted where canvas(for: page.id) == nil {
            guard let canvas = freeCanvas() else { break }
            assign(canvas, to: page.id)
        }
        UIView.performWithoutAnimation {
            for canvas in canvases {
                guard let id = canvas.page, let page = viewport.page(id),
                      let placement = CanvasPlacement.visible(pageFrame: page.frame, in: visible, zoom: viewport.zoomScale)
                else {
                    canvas.placement = nil
                    canvas.view.isHidden = !canvas.isUsingTool
                    continue
                }
                canvas.view.isHidden = false
                place(canvas, placement)
            }
        }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    func place(_ canvas: PageCanvas, _ placement: CanvasPlacement) {
        let view = canvas.view
        let zoom = placement.zoom
        let zoomChanged = view.zoomScale != zoom
        if zoomChanged || view.minimumZoomScale != zoom || view.maximumZoomScale != zoom {
            // Widen the range just enough to set the zoom, then pin it: min == max leaves the canvas no
            // pinch recognizer, so pinches reach the host scroll view and zoom the whole page.
            view.minimumZoomScale = min(view.minimumZoomScale, zoom)
            view.maximumZoomScale = max(view.maximumZoomScale, zoom)
            view.zoomScale = zoom
            view.minimumZoomScale = zoom
            view.maximumZoomScale = zoom
        }
        let scale = placement.scale
        let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
        // Only set what changed: a scroll frame moves the bounds and center, nothing for PencilKit to redo.
        if view.transform != transform {
            view.transform = transform
        }
        if view.contentSize != placement.contentSize {
            view.contentSize = placement.contentSize
        }
        if view.bounds.size != placement.bounds.size {
            view.bounds.size = placement.bounds.size
        }
        if view.contentOffset != placement.bounds.origin {
            view.contentOffset = placement.bounds.origin
        }
        // The scroll view may pixel-align the offset: center on what it took, so page points stay exact.
        let center = placement.center(contentOffset: view.contentOffset)
        if view.center != center {
            view.center = center
        }
        let previous = canvas.placement
        canvas.placement = placement
        guard canvas.hasRendered, previous?.region != placement.region else { return }
        if zoomChanged {
            // New tiles at the new zoom: the old ones scale meanwhile and the raster covers the rest.
            capRenderWait(canvas)
        } else {
            // A scroll: PencilKit draws the scrolled-in tiles at once (cached ones with no callback).
            canvas.renderedRegion = placement.region
        }
    }

    /// Paper, artwork, template, highlights and ink image for every visible page; images keep out of the
    /// region a canvas has drawn. Renders queue nearest the viewport first (`+Images`).
    func layoutPages() {
        let visible = Set(viewport.pages.map(\.id))
        for (id, view) in pageViews where !visible.contains(id) {
            view.removeFromSuperview()
            pageViews[id] = nil
        }
        renderQueue.dropWaiting { !visible.contains($0) }
        let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let frames = Dictionary(viewport.pages.map { ($0.id, $0.frame) }, uniquingKeysWith: { _, last in last })
        renderQueue.priority = { page in frames[page].map { Self.distance(center, $0) } ?? .greatestFiniteMagnitude }
        let colors = PageLayerView.Colors(paper: palette.paper(theme).cgColor, line: palette.templateLine(theme).cgColor)
        let screenScale = host.window?.screen.scale ?? host.traitCollection.displayScale
        // Template marks re-rasterize at the zoom; not mid-pinch (the last settled zoom holds until then).
        let markScale = viewport.isZooming ? nil : min(max(screenScale, 1) * max(viewport.zoomScale, 0.5), 8)
        for page in viewport.pages {
            let view = pageViews[page.id] ?? {
                let view = PageLayerView()
                view.crossfadeDuration = crossfadeDuration
                pagesView.addSubview(view)
                pageViews[page.id] = view
                return view
            }()
            let snapshot = snapshots[page.id]
            view.layout(
                frame: page.frame, template: snapshot?.page.template ?? .blank, leftExtension: snapshot?.leftExtension ?? 0,
                artwork: pageArtwork?(page.id),
                markScale: markScale, colors: colors
            )
            let canvas = canvas(for: page.id)
            guard var snapshot else { continue }
            guard snapshot.isLoaded else {
                // Strokes still loading: the thumbnail stands in for the whole page (its canvas is empty).
                view.inkHole = nil
                showThumbnail(view, for: page.id)
                continue
            }
            refreshHighlights(view, snapshot: snapshot)
            // The image shows wherever the canvas hasn't drawn: around it (zooming out reveals more page),
            // all of it until the canvas has drawn, and the part a scroll or settled zoom just added.
            let drawn = canvas?.drawnRegion
            view.inkHole = drawn
            // A page whose canvas has drawn all it covers needs its image only while a zoom may reveal more.
            guard canvas == nil || drawn != canvas?.placement?.region || viewport.isZooming else { continue }
            if !selection.strokes.isEmpty {
                // Lasso-lifted strokes are drawn by the selection layer, not a canvas or its raster.
                let model = snapshot.page
                let shown = model.strokes.filter { !selection.strokes.contains($0.id) }
                snapshot = PageSnapshot(
                    page: Page(id: model.id, template: model.template, strokes: shown, rev: model.rev),
                    size: snapshot.size, leftExtension: snapshot.leftExtension
                )
            }
            refreshInk(view, snapshot: snapshot, pixelScale: pixelScale(for: page.frame.size, screenScale: screenScale))
        }
    }

    /// Screen scale × zoom rounded up to a power of two (0.5...4), capped by ``maximumRasterDimension``.
    func pixelScale(for size: CGSize, screenScale: CGFloat) -> CGFloat {
        let bucket = [0.5, 1, 2, 4].first { $0 >= viewport.zoomScale } ?? 4
        return min(max(screenScale, 1) * bucket, maximumRasterDimension / max(size.width, size.height, 1))
    }
}
