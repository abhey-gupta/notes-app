import InkEngine
import InkModel
import UIKit

extension PencilKitInkEngine {
    func layoutCanvas() {
        guard let id = activePage, let page = viewport.page(id), let snapshot = snapshots[id] else {
            canvas.isHidden = true
            return
        }
        let pageRect = viewport.viewRect(of: page)
        let visible = pageRect.intersection(CGRect(origin: .zero, size: viewport.size))
        guard !visible.isNull, !visible.isEmpty else {
            canvas.isHidden = true
            return
        }
        let zoom = viewport.zoomScale
        canvas.isHidden = false
        if canvas.zoomScale != zoom || canvas.minimumZoomScale != zoom || canvas.maximumZoomScale != zoom {
            // Widen the range just enough to set the zoom, then pin it: min == max leaves the canvas no
            // pinch recognizer, so pinches reach the host scroll view and zoom the whole page.
            canvas.minimumZoomScale = min(canvas.minimumZoomScale, zoom)
            canvas.maximumZoomScale = max(canvas.maximumZoomScale, zoom)
            canvas.zoomScale = zoom
            canvas.minimumZoomScale = zoom
            canvas.maximumZoomScale = zoom
        }
        canvas.contentSize = CGSize(width: snapshot.size.width * zoom, height: snapshot.size.height * zoom)
        canvas.frame = visible
        canvas.contentOffset = CGPoint(x: visible.minX - pageRect.minX, y: visible.minY - pageRect.minY)
    }

    func layoutPages() {
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
            // The canvas's page keeps its raster until the canvas has drawn it.
            view.showsInk = !isCanvasPage || !canvasHasRendered
            guard let snapshot, !isCanvasPage else { continue }
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
