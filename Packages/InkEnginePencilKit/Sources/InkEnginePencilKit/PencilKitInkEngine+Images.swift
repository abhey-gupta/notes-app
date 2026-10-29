import ImageIO
import InkEngine
import InkModel
import Perf
import UIKit

/// The page-image cache in use (#70): what a page shows while its raster renders, and the render itself.
///
/// Fallback chain, best first: the raster for the current key (cache hit) → the same content at the
/// nearest zoom bucket, scaled → the page's newest raster of any content → the page thumbnail
/// (`thumbs/<id>.heic` via ``InkEngine/InkEngine/thumbnailURL``) → flat paper and template marks.
/// Whatever is on screen stays until the raster replaces it. Renders run on ``RasterRenderQueue``, a few
/// at a time, nearest the viewport first; an edit changes the key, so the page re-renders and its
/// previous rasters are dropped from the cache when the new one lands.
extension PencilKitInkEngine {
    /// Brings a page's ink raster up to date: snapshot strokes plus strokes still pending on the way to the
    /// document, rendered off main by PencilKit. Highlights are the view's own layers, not the raster's.
    func refreshInk(_ view: PageLayerView, snapshot: PageSnapshot, pixelScale: CGFloat) {
        let pendingStrokes = (pending[snapshot.id] ?? []).compactMap(\.pk)
        let key = PageLayerView.InkKey(
            rev: snapshot.rev, theme: theme, pixelScale: pixelScale,
            strokeCount: snapshot.strokes.count, pendingCount: pendingStrokes.count, size: snapshot.size
        )
        guard view.shownKey != key, view.requestedKey != key else { return }
        view.requestedKey = key
        let id = snapshot.id
        let job = RenderJob(page: snapshot, palette: palette, theme: theme, pending: pendingStrokes, layers: .ink)
        guard !job.isEmpty else {
            renderQueue.cancel(id)
            view.setInk(nil, key: key)
            delegate?.engine(self, didShowSharpInkOn: id)
            return
        }
        if let cached = rasters.image(for: id, key: key) {
            renderQueue.cancel(id)
            view.setInk(cached, key: key)
            delegate?.engine(self, didShowSharpInkOn: id)
            return
        }
        if !view.hasImage {
            // A stand-in must cover the same page size, or it would stretch over a widened page (#129).
            if let near = rasters.nearest(for: id, content: key.content, pixelScale: pixelScale, size: key.size)
                ?? rasters.latestImage(for: id, size: key.size)
            {
                view.setStaleInk(near)
            } else {
                showThumbnail(view, for: id)
            }
        }
        renderQueue.enqueue(id, render: { job.ink(scale: pixelScale) }, completion: { [weak self, weak view] image in
            guard let self else { return }
            if let image {
                rasters.insert(image, for: id, key: key)
            }
            guard let view, view.requestedKey == key else { return }
            // A failed render (nil) never clears what is on screen.
            guard image != nil || !view.hasImage else { return }
            view.setInk(image, key: key)
            delegate?.engine(self, didShowSharpInkOn: id)
        })
    }

    /// Shows the page's thumbnail if nothing else is on screen: from the cache, else decoded off main
    /// from ``thumbnailURL`` (a few hundred KB of HEIC) and cached.
    func showThumbnail(_ view: PageLayerView, for id: PageID) {
        guard !view.hasImage else { return }
        if let thumbnail = rasters.thumbnail(for: id) {
            view.setThumbnail(thumbnail)
            return
        }
        guard !thumbnailLoads.contains(id), !thumbnailMisses.contains(id), let url = thumbnailURL?(id) else { return }
        thumbnailLoads.insert(id)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.decodeThumbnail(url) }.value
            guard let self else { return }
            thumbnailLoads.remove(id)
            guard let image else {
                thumbnailMisses.insert(id) // no file (a new notebook): don't stat it every frame
                return
            }
            rasters.insertThumbnail(image, for: id)
            if let view = pageViews[id], !view.hasImage {
                view.setThumbnail(image)
            }
        }
    }

    /// Decodes `url` (HEIC) to a bitmap now, not lazily on the render server's first draw.
    nonisolated static func decodeThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    // MARK: Gauges

    /// Page-image renders in flight at once (#70). Tests serialize them.
    public var maximumConcurrentRenders: Int {
        get { renderQueue.maxConcurrent }
        set { renderQueue.maxConcurrent = newValue }
    }

    /// Memory-warning observer (caches empty, `+Photos`) and the debug HUD gauges.
    func installHousekeeping() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
        registerGauges()
    }

    /// Debug HUD row: resident image MB (ink rasters and thumbnails + artwork bitmaps) and queue depths.
    func registerGauges() {
        PerfHUD.register(gauge: PerfGauge(id: "pageImages", label: "page img") { [weak self] in
            guard let self else { return "–" }
            return String(
                format: "%.1f+%.1f MB · q%d/%d", Double(rasters.bytes) / 1_048_576, Double(artworkRasters.bytes) / 1_048_576,
                renderQueue.depth, artworkQueue.depth + artworkDetailQueue.depth
            )
        })
    }

    /// Bytes of rasters and thumbnails held by the cache (debug HUD, tests).
    public var residentImageBytes: Int {
        rasters.bytes
    }

    /// Renders waiting or running (debug HUD, tests).
    public var renderQueueDepth: Int {
        renderQueue.depth
    }
}
