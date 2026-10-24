import InkEngine
import InkModel
import UIKit

extension PencilKitInkEngine {
    /// Covers the visible part of the active page with the canvas.
    ///
    /// Settled, the canvas is the page's visible rect at the viewport zoom. During a zoom gesture
    /// (``InkEngine/Viewport/isZooming``) it keeps the `zoomScale`, bounds and content offset it had when
    /// the gesture began, and only its center and scale transform follow the pinch (``CanvasPlacement``).
    /// Setting `zoomScale` every frame made PencilKit drop its tiles and re-render them at each new scale
    /// on the GPU, landing frames after the paper (which moves in the same Core Animation transaction as
    /// the viewport): ink slid against the page and snapped back when the pinch stopped. A transform is
    /// composited with the paper, so they move together. When the zoom ends the canvas takes the final
    /// zoom once; PencilKit keeps its old tiles (scaled) until the new ones are drawn.
    func layoutCanvas() {
        syncZoomFreeze()
        layoutSelectionPreview()
        guard let id = activePage, let page = viewport.page(id), let snapshot = snapshots[id] else {
            hideCanvas()
            return
        }
        let pageRect = viewport.viewRect(of: page)
        let placement: CanvasPlacement
        if let freeze = zoom.freeze, freeze.page == id, !freeze.settling {
            placement = .scaled(
                region: freeze.region, renderZoom: freeze.renderZoom, pageOrigin: pageRect.origin,
                zoom: viewport.zoomScale, pageSize: snapshot.size
            )
        } else {
            let visible = pageRect.intersection(CGRect(origin: .zero, size: viewport.size))
            guard !visible.isNull, !visible.isEmpty else {
                hideCanvas()
                return
            }
            placement = .settled(visible: visible, pageRect: pageRect, zoom: viewport.zoomScale, pageSize: snapshot.size)
        }
        canvas.isHidden = false
        place(placement)
        zoom.placedPage = id
    }

    private func hideCanvas() {
        canvas.isHidden = true
        zoom.placedPage = nil
    }

    private func place(_ placement: CanvasPlacement) {
        let renderZoom = placement.renderZoom
        if canvas.zoomScale != renderZoom || canvas.minimumZoomScale != renderZoom || canvas.maximumZoomScale != renderZoom {
            // Widen the range just enough to set the zoom, then pin it: min == max leaves the canvas no
            // pinch recognizer, so pinches reach the host scroll view and zoom the whole page.
            canvas.minimumZoomScale = min(canvas.minimumZoomScale, renderZoom)
            canvas.maximumZoomScale = max(canvas.maximumZoomScale, renderZoom)
            canvas.zoomScale = renderZoom
            canvas.minimumZoomScale = renderZoom
            canvas.maximumZoomScale = renderZoom
        }
        let scale = placement.scale
        let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
        // Only set what changed: mid-zoom that is the center and transform, so PencilKit has nothing to redo.
        if canvas.transform != transform {
            canvas.transform = transform
        }
        if canvas.contentSize != placement.contentSize {
            canvas.contentSize = placement.contentSize
        }
        if canvas.bounds.size != placement.bounds.size {
            canvas.bounds.size = placement.bounds.size
        }
        if canvas.center != placement.center {
            canvas.center = placement.center
        }
        if canvas.contentOffset != placement.bounds.origin {
            canvas.contentOffset = placement.bounds.origin
        }
    }

    /// Starts, keeps, settles or drops the zoom freeze for the current viewport and active page.
    func syncZoomFreeze() {
        guard let id = activePage, viewport.page(id) != nil, snapshots[id] != nil else {
            zoom.freeze = nil
            return
        }
        if viewport.isZooming {
            if let freeze = zoom.freeze, freeze.page == id, !freeze.settling {
                return
            }
            // Hold what the canvas shows now, if it is on this page (else it is placed normally this
            // frame and held from the next).
            let renderZoom = canvas.zoomScale
            let bounds = canvas.bounds
            guard zoom.placedPage == id, !canvas.isHidden, renderZoom > 0, !bounds.isEmpty else {
                zoom.freeze = nil
                return
            }
            let region = CGRect(
                x: bounds.minX / renderZoom, y: bounds.minY / renderZoom,
                width: bounds.width / renderZoom, height: bounds.height / renderZoom
            )
            zoom.freeze = ZoomFreeze(page: id, region: region, renderZoom: renderZoom)
        } else if var freeze = zoom.freeze, freeze.page == id {
            guard !freeze.settling else { return }
            freeze.settling = true
            zoom.freeze = freeze
            zoom.settleToken += 1
            // `canvasViewDidFinishRendering` normally comes within a few frames; don't wait on it forever.
            let token = zoom.settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, zoom.settleToken == token else { return }
                zoomDidSettle()
            }
        } else {
            zoom.freeze = nil
        }
    }

    /// The canvas finished rendering (or the settle timed out). After a zoom, the active page's raster
    /// hides again; mid-zoom, it re-applies the raster around the held canvas (`canvasDidRender` may
    /// just have hidden it).
    func zoomDidSettle() {
        guard let freeze = zoom.freeze else { return }
        if freeze.settling, !viewport.isZooming {
            zoom.freeze = nil
        }
        layoutPages()
    }

    func layoutPages() {
        syncZoomFreeze()
        let visible = Set(viewport.pages.map(\.id))
        for (id, view) in pageViews where !visible.contains(id) {
            view.removeFromSuperview()
            pageViews[id] = nil
        }
        let colors = PageLayerView.Colors(paper: palette.paper(theme).cgColor, line: palette.templateLine(theme).cgColor)
        let screenScale = host.window?.screen.scale ?? host.traitCollection.displayScale
        for page in viewport.pages {
            let view = pageViews[page.id] ?? {
                let view = PageLayerView()
                pagesView.addSubview(view)
                pageViews[page.id] = view
                return view
            }()
            let snapshot = snapshots[page.id]
            view.layout(
                frame: viewport.viewRect(of: page),
                template: snapshot?.page.template ?? .blank,
                size: page.frame.size,
                zoom: viewport.zoomScale,
                colors: colors
            )
            let isCanvasPage = page.id == activePage
            // During a zoom, and until the canvas has redrawn after it, the canvas covers only what it had
            // drawn when the zoom began; the page's raster shows around that (zooming out reveals more page).
            let freeze = isCanvasPage && zoom.freeze?.page == page.id ? zoom.freeze : nil
            let hole = canvasHasRendered ? freeze?.region : nil
            view.inkHole = hole
            // The canvas's page keeps its raster until the canvas has drawn it.
            view.showsInk = !isCanvasPage || !canvasHasRendered || hole != nil
            guard var snapshot, !isCanvasPage || freeze != nil else { continue }
            if isCanvasPage, !selection.strokes.isEmpty {
                // Lasso-lifted strokes are drawn by the selection layer, not the canvas or its raster.
                let model = snapshot.page
                let shown = model.strokes.filter { !selection.strokes.contains($0.id) }
                snapshot = PageSnapshot(
                    page: Page(id: model.id, template: model.template, strokes: shown, rev: model.rev),
                    size: snapshot.size
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

    /// Brings an inactive page's raster up to date: snapshot strokes plus strokes still pending on the
    /// way to the document, rendered off main by PencilKit. Whatever is on screen (current raster, a
    /// stale one from the cache, or the canvas snapshot) stays until the new raster replaces it.
    func refreshInk(_ view: PageLayerView, snapshot: PageSnapshot, pixelScale: CGFloat) {
        let pendingStrokes = (pending[snapshot.id] ?? []).map(\.pk)
        let key = PageLayerView.InkKey(
            rev: snapshot.rev, theme: theme, pixelScale: pixelScale,
            strokeCount: snapshot.strokes.count, pendingCount: pendingStrokes.count
        )
        if view.shownKey == key {
            view.removePlaceholder()
            return
        }
        guard view.requestedKey != key else { return }
        view.requestedKey = key
        let job = RenderJob(page: snapshot, palette: palette, theme: theme, pending: pendingStrokes)
        guard !job.isEmpty else {
            view.setInk(nil, key: key)
            return
        }
        let id = snapshot.id
        if let cached = rasters.image(for: id, key: key) {
            view.setInk(cached, key: key)
            return
        }
        if view.shownKey == nil, !view.hasPlaceholder, let stale = rasters.latestImage(for: id) {
            view.setStaleInk(stale)
        }
        Task { [weak self, weak view] in
            let image = await Task.detached(priority: .userInitiated) { job.ink(scale: pixelScale) }.value
            if let image {
                self?.rasters.insert(image, for: id, key: key)
            }
            guard let view, view.requestedKey == key else { return }
            view.setInk(image, key: key)
        }
    }
}
