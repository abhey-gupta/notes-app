import ImageIO
import InkEngine
import InkModel
import UIKit

/// Photos on pages (#157): each `PageLayerView` draws its page's images as layers beneath the highlights
/// and ink, so they scroll and zoom with the paper and cost nothing per frame. Bytes come from
/// ``InkEngine/InkEngine/imageURL`` (`images/<asset>.heic`), decoded off main once into ``PhotoCache``
/// (emptied on a memory warning); until then the layer shows a faint placeholder of the frame.
///
/// A lasso drag moves the selected photos' layers in place (``PhotoPreview``), so they stay under the
/// ink while the lifted ink image moves above; the baked edit then lands them where they were shown.
extension PencilKitInkEngine {
    /// Rasters and decoded photos go; page views re-request what they show.
    @objc func didReceiveMemoryWarning() {
        rasters.removeAll()
        photos.removeAll()
    }

    /// Brings a page view's photo layers up to date (frames, bitmaps, drag preview).
    func refreshPhotos(_ view: PageLayerView, snapshot: PageSnapshot) {
        let preview = selection.photoPreview.flatMap { $0.page == snapshot.id ? $0 : nil }
        view.setPhotos(snapshot.images, lifted: preview?.images ?? [], transform: preview?.transform ?? .identity) { asset in
            photos.image(for: asset) ?? loadPhoto(asset)
        }
    }

    /// Moves (or puts back) the photos of a drag preview; only their page re-lays out.
    func setPhotoPreview(_ next: PhotoPreview?) {
        let previous = selection.photoPreview
        guard previous != next else { return }
        selection.photoPreview = next
        for page in Set([previous?.page, next?.page].compactMap(\.self)) {
            if let view = pageViews[page], let snapshot = snapshots[page] {
                refreshPhotos(view, snapshot: snapshot)
            }
        }
    }

    /// Decodes `asset` off main if nothing is in flight for it; the page views refresh when it lands.
    /// Returns `nil` (the placeholder shows meanwhile).
    private func loadPhoto(_ asset: ImageAssetID) -> CGImage? {
        guard photos.beginLoad(asset), let url = imageURL?(asset) else { return nil }
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { PhotoCache.decode(url) }.value
            guard let self else { return }
            photos.endLoad(asset, image: image)
            if image != nil {
                layoutPages()
            }
        }
        return nil
    }

    /// Thumbnails and export fallback: paper + artwork + template + photos + ink, drawn by PencilKit from
    /// the stored strokes. Photos not yet decoded are read from ``imageURL`` off main.
    public func render(page: PageSnapshot, size: CGSize, scale: CGFloat) async -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0, page.size.width > 0, page.size.height > 0 else { return nil }
        var job = RenderJob(page: page, palette: palette, theme: theme, artwork: pageArtwork?(page.id))
        let sources = photoSources(for: page)
        return await Task.detached(priority: .userInitiated) {
            job.photos = PhotoCache.resolve(sources)
            return job.page(size: size, scale: scale)
        }.value
    }

    /// What ``render(page:size:scale:)`` needs to draw a page's photos: decoded bitmaps where the cache has
    /// them, URLs otherwise (decoded on the render's own task).
    func photoSources(for page: PageSnapshot) -> [PhotoCache.Source] {
        page.images.compactMap { image in
            if let cg = photos.image(for: image.asset) {
                return .decoded(cg, frame: image.frame)
            }
            guard let url = imageURL?(image.asset) else { return nil }
            return .file(url, frame: image.frame)
        }
    }
}

/// A lasso drag's photos: shown at their frames moved by `transform` until the edit lands.
struct PhotoPreview: Hashable {
    let page: PageID
    let images: Set<ImageID>
    let transform: CGAffineTransform
}

/// Decoded photo bitmaps by asset, plus which assets are loading or missing (so a missing file isn't
/// stat'ed every frame). ``decode(_:)`` is also the app's PDF export loader.
@MainActor
public final class PhotoCache {
    private var images: [ImageAssetID: CGImage] = [:]
    private var loading: Set<ImageAssetID> = []
    private var missing: Set<ImageAssetID> = []

    /// A decoded photo source for an off-main render.
    enum Source: Sendable {
        case decoded(CGImage, frame: CGRect)
        case file(URL, frame: CGRect)
    }

    func image(for asset: ImageAssetID) -> CGImage? {
        images[asset]
    }

    /// Whether a load should start now (nothing cached, in flight or known missing).
    func beginLoad(_ asset: ImageAssetID) -> Bool {
        guard images[asset] == nil, !loading.contains(asset), !missing.contains(asset) else { return false }
        loading.insert(asset)
        return true
    }

    func endLoad(_ asset: ImageAssetID, image: CGImage?) {
        loading.remove(asset)
        if let image {
            images[asset] = image
        } else {
            missing.insert(asset)
        }
    }

    /// A photo file was written (or an earlier miss is stale): the next layout tries again.
    func forget(_ asset: ImageAssetID) {
        missing.remove(asset)
    }

    func removeAll() {
        images.removeAll()
        missing.removeAll()
    }

    /// Bytes of decoded photos (debug HUD, tests).
    var bytes: Int {
        images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    /// Decodes `url` (HEIC or JPEG) to a bitmap now, not lazily on first draw.
    public nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Resolves render sources to photos, decoding files (each once) off main.
    nonisolated static func resolve(_ sources: [Source]) -> [RenderJob.Photo] {
        var decoded: [URL: CGImage] = [:]
        return sources.compactMap { source in
            switch source {
            case let .decoded(image, frame):
                return RenderJob.Photo(image: image, frame: frame)
            case let .file(url, frame):
                let image = decoded[url] ?? decode(url)
                guard let image else { return nil }
                decoded[url] = image
                return RenderJob.Photo(image: image, frame: frame)
            }
        }
    }
}
