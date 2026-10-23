import CoreGraphics
import Foundation
import InkEngine
import InkModel
import Metal

/// How the engine shows committed content (ARCHITECTURE.md §5.4).
public enum CommittedContentMode: Sendable {
    /// Cached page tiles rendered off main (``TiledContentRenderer``).
    case tiles
    /// One viewport-sized composite re-rendered on every change (#19), kept for A/B until tiles are
    /// verified on device.
    case viewportComposite

    /// User-defaults key (launch argument `-inkViewportComposite YES`) selecting the composite.
    public static let compositeDefaultsKey = "inkViewportComposite"

    /// ``tiles`` unless the ``compositeDefaultsKey`` user default is set.
    public static var `default`: CommittedContentMode {
        UserDefaults.standard.bool(forKey: compositeDefaultsKey) ? .viewportComposite : .tiles
    }
}

// MARK: - Canvas host hooks

public extension MetalInkEngine {
    /// A pinch began (`scrollViewWillBeginZooming`): existing tiles are scaled until
    /// ``endZoomGesture()``. Without these calls the engine infers a pinch from the zoom changing
    /// between frames and re-renders once it has been still for 150 ms.
    func beginZoomGesture() {
        tiles?.beginZoomGesture()
    }

    /// The pinch ended (`scrollViewDidEndZooming`): tiles for the final zoom render now.
    func endZoomGesture() {
        tiles?.endZoomGesture()
        driver.requestFrame()
    }

    /// The page's thumbnail (e.g. decoded `thumbs/<pageID>.heic`): shown where a tile isn't ready and
    /// no other zoom level covers it, instead of bare paper. `nil` clears it; the host owns its lifetime
    /// (clear it for pages it no longer sends).
    func setThumbnail(_ image: CGImage?, for page: PageID) {
        guard let tiles else { return }
        tiles.setThumbnail(image.flatMap { ThumbnailTexture.make($0, device: gpu.device) }, for: page)
        driver.requestFrame()
    }
}

// MARK: - Residency

extension MetalInkEngine {
    /// Pages either side of the visible ones whose GPU buffers and strips are kept (ARCHITECTURE.md §5.4).
    static let bufferRadius = 3
    /// Pages either side of the visible ones whose tiles are prefetched (in ``Viewport/pages``).
    static let tileRadius = 1

    /// Whether `page` is within ``bufferRadius`` of the visible pages (always, before any viewport).
    func isInBufferWindow(_ page: PageID) -> Bool {
        guard let bufferWindow, let index = pageOrder[page] else { return true }
        return bufferWindow.contains(index)
    }

    /// Recomputes the buffer window from the visible pages; drops buffers that left it and builds the
    /// pages that entered it.
    func updateBufferWindow() {
        let bounds = CGRect(origin: .zero, size: viewport.size)
        let visible = viewport.pages.filter { viewport.viewRect(of: $0).intersects(bounds) }.compactMap { pageOrder[$0.id] }
        guard let lo = visible.min(), let hi = visible.max() else { return }
        let window = (lo - Self.bufferRadius) ... (hi + Self.bufferRadius)
        guard window != bufferWindow else { return }
        bufferWindow = window
        tiles?.retainPages(Set(pageOrder.filter { window.contains($0.value) }.keys))
        for (id, index) in pageOrder {
            if window.contains(index) {
                if pageBuffers[id] == nil, buildTasks[id] == nil {
                    scheduleBuild(id)
                }
            } else if pageBuffers[id] != nil || buildTasks[id] != nil {
                releaseBuffers(id)
            }
        }
    }

    /// Drops `page`'s GPU buffers, in-flight build and cached strips (its tiles stay valid).
    private func releaseBuffers(_ page: PageID) {
        pageBuffers[page] = nil
        buildTasks[page]?.task.cancel()
        buildTasks[page] = nil
        rebuildAfterCurrent.remove(page)
        for stroke in snapshots[page]?.strokes ?? [] {
            meshCache[stroke.id] = nil
        }
    }

    // MARK: Invalidation

    /// Tells the content renderer what `buffers` change on `page` relative to what it shows: the diff
    /// against the previous build, the whole page if the look changed while unbuilt, plus explicit
    /// ``invalidate(_:in:)`` rects once the last build they caused lands.
    func invalidateContent(_ page: PageID, installing buffers: PageBuffers, last: Bool) {
        var dirty: CGRect?
        if let old = pageBuffers[page] {
            dirty = PageDiff.dirtyRect(from: old, to: buffers)
        } else if signatures[page] == PageSignature(buffers) {
            dirty = .null
        }
        if last, let extra = explicitInvalidations.removeValue(forKey: page) {
            dirty = dirty.map { $0.union(extra) }
        }
        if let dirty {
            if !dirty.isNull {
                content.invalidate(page: page, rect: dirty)
            }
        } else {
            content.invalidate(page: page, rect: nil)
        }
    }

    /// Drops pending strokes once the content shown for their page includes them.
    func prunePending() {
        for (page, list) in pending where !list.isEmpty {
            guard let buffers = pageBuffers[page], content.isSettled(page: page) else { continue }
            pending[page] = list.filter { !buffers.strokeIDs.contains($0.stroke.id) }
        }
    }
}

/// Page thumbnail → shader-readable texture (sRGB-encoded BGRA, like every target).
enum ThumbnailTexture {
    static func make(_ image: CGImage, device: any MTLDevice) -> (any MTLTexture)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= OffscreenRenderer.maximumDimension, height <= OffscreenRenderer.maximumDimension,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: GPUContext.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "ink.thumbnail"
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
        }
        return texture
    }
}
