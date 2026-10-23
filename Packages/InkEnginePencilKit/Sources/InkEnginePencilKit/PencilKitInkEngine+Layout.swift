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
        if canvas.zoomScale != zoom {
            canvas.minimumZoomScale = min(canvas.minimumZoomScale, zoom)
            canvas.maximumZoomScale = max(canvas.maximumZoomScale, zoom)
            canvas.zoomScale = zoom
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
            view.showsInk = page.id != activePage
            guard let snapshot, page.id != activePage else { continue }
            refreshInk(view, snapshot: snapshot, pixelScale: pixelScale(for: page.frame.size, screenScale: screenScale))
        }
    }

    /// Screen scale × zoom rounded up to a power of two (0.5...4), capped by ``maximumRasterDimension``.
    func pixelScale(for size: CGSize, screenScale: CGFloat) -> CGFloat {
        let bucket = [0.5, 1, 2, 4].first { $0 >= viewport.zoomScale } ?? 4
        return min(max(screenScale, 1) * bucket, maximumRasterDimension / max(size.width, size.height, 1))
    }

    func refreshInk(_ view: PageLayerView, snapshot: PageSnapshot, pixelScale: CGFloat) {
        let key = PageLayerView.InkKey(rev: snapshot.rev, theme: theme, pixelScale: pixelScale, strokeCount: snapshot.strokes.count)
        guard view.inkKey != key else { return }
        view.inkKey = key
        guard !snapshot.strokes.isEmpty else {
            view.setInk(nil)
            return
        }
        let job = RenderJob(page: snapshot, palette: palette, theme: theme)
        Task { [weak view] in
            let image = await Task.detached(priority: .userInitiated) { job.ink(scale: pixelScale) }.value
            guard let view, view.inkKey == key else { return }
            view.setInk(image)
        }
    }
}
