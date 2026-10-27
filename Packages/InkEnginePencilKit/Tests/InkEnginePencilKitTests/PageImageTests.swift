import CoreGraphics
import ImageIO
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing
import UniformTypeIdentifiers

/// The page-image cache in use (#70) and the thumbnail-first open (#43): what a page shows while its
/// strokes load and its raster renders, and when the app learns it is sharp.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct PageImageTests {
    /// A 44 × 57 HEIC (the 176 × 228 thumbnail's shape) at `thumbs/<id>.heic` in a temp directory.
    private static func writeThumbnail(for id: PageID) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 44, height: 57, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 44, height: 57))
        let image = try #require(context.makeImage())
        let url = dir.appending(path: "\(id).heic")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    /// A page whose strokes are still loading shows its thumbnail scaled up, whole (no canvas hole); when
    /// the strokes arrive the raster replaces it and the app hears the page is sharp.
    @Test func unloadedPageShowsItsThumbnailUntilTheRasterLands() async throws {
        let h = Harness()
        h.engine.maximumConcurrentRenders = 1
        let id = h.frames[0].id
        let url = try Self.writeThumbnail(for: id)
        h.engine.thumbnailURL = { $0 == id ? url : nil }
        var pages = h.snapshots
        pages[0] = PageSnapshot(page: Page(id: id, template: .blank), size: RenderFixtures.pageSize, isLoaded: false)
        h.engine.setPages(pages)
        h.scroll(toY: 0)
        let view = try #require(h.engine.pageViews[id])
        try await waitUntil { view.showsThumbnail }
        #expect(view.thumbnailLayer.frame.width == 595)
        #expect(abs(view.thumbnailLayer.frame.height - 595 * 57 / 44) < 1, "top-aligned, page width, thumbnail shape")
        try h.engine.canvasViewDidFinishRendering(#require(h.canvas(0)).view)
        #expect(view.inkHole == nil, "an empty canvas doesn't cut the thumbnail")
        #expect(!h.recorder.sharp.contains(id), "not sharp yet (loaded pages 2–3 may be)")
        #expect(h.engine.residentImageBytes > 0, "the decoded thumbnail is cached")

        pages[0] = h.snapshots[0].appending([RenderFixtures.line(1, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 50))])
        h.engine.setPages(pages)
        #expect(view.showsThumbnail, "the thumbnail stays until the raster is ready")
        try await waitUntil { view.shownKey != nil }
        #expect(!view.showsThumbnail)
        #expect(h.recorder.sharp.contains(id))
        #expect(h.engine.renderQueueDepth == 0)
    }

    /// Zooming asks for another bucket: the shown raster stays (scaled by the layer) until the new one
    /// renders, after which the cache holds both; an edit drops them both for the new content.
    @Test func zoomKeepsTheShownRasterAndEditInvalidates() async throws {
        let h = Harness()
        h.engine.maximumConcurrentRenders = 1
        h.engine.maximumCanvases = 1
        h.scroll(toY: 0) // pages 1–2 visible: page 1 takes the one canvas, page 2 (one stroke) is a raster
        let id = h.frames[1].id
        let view = try #require(h.engine.pageViews[id])
        try await waitUntil { view.shownKey != nil }
        let key1 = try #require(view.shownKey)
        let scale1 = key1.pixelScale
        h.scroll(toY: 0, zoom: 2)
        #expect(view.hasImage && view.shownKey == key1, "the old bucket stays on screen, scaled")
        try await waitUntil { view.shownKey?.pixelScale == scale1 * 2 }
        #expect(h.engine.rasters.count == 2, "both buckets cached")
        #expect(h.engine.rasters.nearest(for: id, content: key1.content, pixelScale: scale1, size: key1.size) != nil)

        let page = try #require(h.engine.snapshots[id]).page
        h.engine.apply(page.addEdit([RenderFixtures.line(2, from: CGPoint(x: 10, y: 400), to: CGPoint(x: 300, y: 400))]), to: id)
        try await waitUntil { view.shownKey?.strokeCount == 2 }
        #expect(h.engine.rasters.count == 1, "the edit invalidated the old content's buckets")
    }
}
