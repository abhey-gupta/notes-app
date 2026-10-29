import CoreGraphics
import InkEngine
import InkModel

/// Imported artwork (PDF pages, #119) on screen (#193): one whole-page bitmap per zoom bucket, rendered
/// off main (``artworkQueue``, one at a time: a PDF's pages draw under one lock), cached across visits
/// (``artworkRasters``) and prefetched for the pages the host keeps resident around the viewport, so a
/// page flip finds its bitmap ready. While a bucket renders the page shows its nearest cached bucket
/// (scaled by the layer), else its thumbnail (which has the artwork baked in), else paper. When the
/// zoom outgrows the bitmap (`maximumRasterDimension` caps it, ≈ 2.4× on A4 at 2×) the visible part of
/// the page renders at full screen resolution into the layer's detail (``artworkDetailQueue``), once the
/// zoom settles, with a margin so a short scroll stays sharp.
extension PencilKitInkEngine {
    /// Whole-page artwork bitmaps per zoom bucket, kept across visits.
    var artworkRasters: ArtworkRasterCache {
        artworkPipeline.rasters
    }

    /// Whole-page artwork renders, one at a time (a PDF's pages draw under one lock), nearest first.
    var artworkQueue: RasterRenderQueue {
        artworkPipeline.bitmaps
    }

    /// Deep-zoom detail renders of the visible part of a page.
    var artworkDetailQueue: RasterRenderQueue {
        artworkPipeline.details
    }

    /// Whole-page artwork renders waiting or running, by page.
    var artworkRequests: [PageID: ArtworkLayer.Key] {
        get { artworkPipeline.requests }
        set { artworkPipeline.requests = newValue }
    }

    /// `layoutPages`' artwork step: the bitmap, and the thumbnail standing in until the first one lands.
    func layoutArtwork(_ view: PageLayerView, page: VisiblePage, screenScale: CGFloat) {
        refreshArtwork(view, page: page, screenScale: screenScale)
        if !view.isArtworkReady {
            // The artwork's first bitmap is rendering: the thumbnail (artwork baked in) stands in.
            showThumbnail(view, for: page.id)
        }
    }

    /// Brings `view`'s artwork bitmap up to date for the current zoom and, at deep zoom, its detail.
    func refreshArtwork(_ view: PageLayerView, page: VisiblePage, screenScale: CGFloat) {
        guard let layer = view.artworkLayer, let artwork = layer.artwork else { return }
        let id = page.id
        let key = ArtworkLayer.Key(size: page.frame.size, pixelScale: pixelScale(for: page.frame.size, screenScale: screenScale))
        if layer.shownKey != key {
            if let cached = artworkRasters.image(for: id, key: key) {
                layer.setImage(cached, key: key)
                view.artworkDidChange()
            } else {
                if !layer.hasImage, let near = artworkRasters.nearest(for: id, key: key) {
                    layer.setImage(near.image, key: near.key)
                    view.artworkDidChange()
                }
                requestArtwork(id, artwork: artwork, key: key)
            }
        }
        refreshArtworkDetail(view, page: page, bucket: key, screenScale: screenScale)
    }

    /// Renders the bitmaps of resident pages that aren't on screen (the host keeps a page either side of
    /// the viewport), lowest priority, so a page flip finds them cached. Not at deep zoom (a bitmap is
    /// tens of MB there and the zoom is likely to change).
    func prefetchArtwork(visible: Set<PageID>, screenScale: CGFloat) {
        guard !viewport.isZooming, let pageArtwork else { return }
        for (id, snapshot) in snapshots where !visible.contains(id) {
            guard let artwork = pageArtwork(id) else { continue }
            let key = ArtworkLayer.Key(size: snapshot.size, pixelScale: pixelScale(for: snapshot.size, screenScale: screenScale))
            guard key.pixelScale <= max(screenScale, 1) * 2, artworkRasters.image(for: id, key: key) == nil else { continue }
            requestArtwork(id, artwork: artwork, key: key)
        }
    }

    /// Queues the whole-page render of `key` unless it is already waiting or running.
    private func requestArtwork(_ id: PageID, artwork: any PageArtwork, key: ArtworkLayer.Key) {
        guard artworkRequests[id] != key else { return }
        artworkRequests[id] = key
        let render: @Sendable () -> CGImage? = { ArtworkLayer.renderImage(artwork, size: key.size, pixelScale: key.pixelScale) }
        artworkQueue.enqueue(id, render: render, completion: { [weak self] image in
            guard let self else { return }
            if artworkRequests[id] == key {
                artworkRequests[id] = nil
            }
            guard let image else { return }
            artworkRasters.insert(image, for: id, key: key)
            artworkDidRender(id, image: image, key: key)
        })
    }

    /// A whole-page bitmap landed: the page view (if the page is still on screen) shows it when it is
    /// the one the zoom wants now (it may have moved on), or when it has nothing better.
    private func artworkDidRender(_ id: PageID, image: CGImage, key: ArtworkLayer.Key) {
        guard let view = pageViews[id], let layer = view.artworkLayer, let page = viewport.page(id) else { return }
        let wanted = ArtworkLayer.Key(size: page.frame.size, pixelScale: pixelScale(for: page.frame.size, screenScale: screenScale))
        guard wanted == key || !layer.hasImage else { return }
        layer.setImage(image, key: key)
        view.artworkDidChange()
        refreshArtworkDetail(view, page: page, bucket: wanted, screenScale: screenScale)
    }

    /// Renders the visible part of the page at screen resolution into the layer's detail when `bucket`
    /// (the whole-page bitmap the view wants) is softer than the screen; clears it otherwise. Left alone
    /// mid-zoom: the host's transform scales what is there until the zoom settles.
    func refreshArtworkDetail(_ view: PageLayerView, page: VisiblePage, bucket: ArtworkLayer.Key, screenScale: CGFloat) {
        guard let layer = view.artworkLayer, let artwork = layer.artwork, !viewport.isZooming else { return }
        let id = page.id
        let want = max(screenScale, 1) * viewport.zoomScale
        let visiblePart = visibleRect.intersection(page.frame).offsetBy(dx: -page.frame.minX, dy: -page.frame.minY)
        guard want > bucket.pixelScale * 1.05, !visiblePart.isNull, !visiblePart.isEmpty else {
            // The bitmap is sharp enough: the detail goes once that bitmap is on screen (not before,
            // or a zoom out past the cap would soften the page until the new bucket lands).
            if layer.shownKey == bucket || layer.shownDetail == nil {
                layer.clearDetail()
            }
            layer.requestedDetail = nil
            artworkDetailQueue.cancel(id)
            return
        }
        if let shown = layer.shownDetail, shown.pixelScale == want, shown.rect.contains(visiblePart) {
            // Still inside the margin: nothing to do (and nothing older to wait for).
            layer.requestedDetail = nil
            artworkDetailQueue.cancel(id)
            return
        }
        let pageRect = CGRect(origin: .zero, size: page.frame.size)
        let rect = visiblePart.insetBy(dx: -visiblePart.width * Self.detailMargin, dy: -visiblePart.height * Self.detailMargin)
            .intersection(pageRect).integral.intersection(pageRect)
        let key = ArtworkLayer.DetailKey(rect: rect, pixelScale: want)
        guard layer.requestedDetail != key else { return }
        layer.requestedDetail = key
        let size = page.frame.size
        let render: @Sendable () -> CGImage? = { ArtworkLayer.render(artwork, rect: rect, pageSize: size, pixelScale: want) }
        artworkDetailQueue.enqueue(id, render: render, completion: { [weak layer] image in
            guard let layer, layer.requestedDetail == key else { return }
            layer.requestedDetail = nil
            if let image {
                layer.setDetail(image, key: key)
            }
        })
    }

    /// How far beyond the visible part a detail render reaches, per side, as a fraction of it.
    static let detailMargin: CGFloat = 0.1

    /// The screen's scale as the page views see it.
    var screenScale: CGFloat {
        host.window?.screen.scale ?? host.traitCollection.displayScale
    }

    /// Whole-page artwork bitmaps cached (tests, debug).
    public var residentArtworkBytes: Int {
        artworkRasters.bytes
    }

    /// Artwork renders (bitmaps and details) waiting or running (tests).
    public var artworkQueueDepth: Int {
        artworkQueue.depth + artworkDetailQueue.depth
    }
}

/// The engine's artwork state (#193): the bitmap cache and the two render queues, one render at a time
/// each (a PDF's pages draw under one lock; more in flight would only contend with the ink renders).
@MainActor
final class ArtworkPipeline {
    let rasters = ArtworkRasterCache()
    let bitmaps = RasterRenderQueue(signpost: .artworkRender)
    let details = RasterRenderQueue(signpost: .artworkRender)
    var requests: [PageID: ArtworkLayer.Key] = [:]

    init() {
        bitmaps.maxConcurrent = 1
        details.maxConcurrent = 1
    }
}
