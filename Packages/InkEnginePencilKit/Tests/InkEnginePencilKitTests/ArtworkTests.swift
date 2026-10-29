import CoreGraphics
import Foundation
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing

/// Page artwork drawn as a red square in the page's top-left quarter; counts its draws, and can hold
/// each draw until the test lets it through.
final class CountingArtwork: PageArtwork, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let gate = DispatchSemaphore(value: 0)
    private let gated: Bool

    init(gated: Bool = false) {
        self.gated = gated
    }

    var draws: Int {
        lock.withLock { count }
    }

    /// Lets one held draw through.
    func release() {
        gate.signal()
    }

    func draw(in context: CGContext, size: CGSize) {
        if gated {
            gate.wait()
        }
        lock.withLock { count += 1 }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
    }
}

/// Imported artwork on screen (#193): one cached bitmap per zoom bucket, kept across visits and
/// prefetched for resident pages; the thumbnail covers the first render; deep zoom gets a detail pass.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct ArtworkTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func show(_ h: Harness, pages: [Int], zoom: CGFloat = 1, y: CGFloat = 0, size: CGSize? = nil) {
        h.engine.setViewport(Viewport(
            contentOffset: CGPoint(x: 0, y: y), zoomScale: zoom, size: size ?? h.viewSize, pages: pages.map { h.frames[$0] }
        ))
    }

    /// The first visit renders the page's bitmap once, off main; scrolled away and back, the new page
    /// view shows it at once from the cache.
    @Test func bitmapRendersOnceAndReappearsFromTheCache() async throws {
        let h = Harness()
        let id = h.frames[0].id
        let art = CountingArtwork()
        h.engine.pageArtwork = { $0 == id ? art : nil }
        show(h, pages: [0])
        let view = try #require(h.engine.pageViews[id])
        let layer = try #require(view.artworkLayer)
        #expect(!layer.hasImage && !view.isArtworkReady)
        try await waitUntil { layer.shownKey != nil }
        #expect(art.draws == 1)
        #expect(layer.shownKey?.size == RenderFixtures.pageSize)
        #expect(h.engine.artworkRasters.count == 1 && h.engine.residentArtworkBytes > 0)

        show(h, pages: [2], y: 2000)
        #expect(h.engine.pageViews[id] == nil, "the page view went with the page")
        show(h, pages: [0])
        let back = try #require(h.engine.pageViews[id])
        #expect(back !== view)
        #expect(back.artworkLayer?.hasImage == true, "shown synchronously from the cache")
        #expect(back.isArtworkReady)
        try await Task.sleep(for: .milliseconds(50))
        #expect(art.draws == 1, "no second render")
        #expect(h.engine.artworkQueueDepth == 0)
    }

    /// A page with artwork and no ink keeps its thumbnail (artwork baked in) over the empty layer until
    /// the first bitmap lands, then crossfades it out.
    @Test func thumbnailStaysUntilTheFirstBitmapLands() async throws {
        let h = Harness()
        let id = h.frames[0].id
        let url = try PageImageTests.writeThumbnail(for: id)
        h.engine.thumbnailURL = { $0 == id ? url : nil }
        let art = CountingArtwork(gated: true)
        h.engine.pageArtwork = { $0 == id ? art : nil }
        show(h, pages: [0])
        let view = try #require(h.engine.pageViews[id])
        try await waitUntil { view.showsThumbnail }
        #expect(view.shownKey != nil, "the (empty) ink settled")
        #expect(view.showsThumbnail && !view.isArtworkReady, "the thumbnail waits for the artwork")
        art.release()
        try await waitUntil { view.isArtworkReady }
        #expect(!view.showsThumbnail)
    }

    /// Zooming in asks for the next bucket: the shown bitmap stays (scaled) until it renders; zooming
    /// back out finds the old bucket cached.
    @Test func zoomKeepsTheShownBitmapAndCachesEveryBucket() async throws {
        let h = Harness()
        let id = h.frames[0].id
        let art = CountingArtwork()
        h.engine.pageArtwork = { $0 == id ? art : nil }
        show(h, pages: [0])
        let view = try #require(h.engine.pageViews[id])
        let layer = try #require(view.artworkLayer)
        try await waitUntil { layer.shownKey != nil }
        let scale1 = try #require(layer.shownKey?.pixelScale)
        show(h, pages: [0], zoom: 2)
        #expect(layer.shownKey?.pixelScale == scale1, "the old bucket stays on screen, scaled")
        try await waitUntil { layer.shownKey?.pixelScale == scale1 * 2 }
        #expect(h.engine.artworkRasters.count == 2 && art.draws == 2)
        show(h, pages: [0], zoom: 1)
        #expect(layer.shownKey?.pixelScale == scale1, "cache hit, synchronous")
        try await Task.sleep(for: .milliseconds(30))
        #expect(art.draws == 2)
    }

    /// Resident pages beside the viewport render after the visible ones, so a flip finds them cached.
    @Test func prefetchesResidentPagesAroundTheViewport() async throws {
        let h = Harness()
        let arts = Dictionary(uniqueKeysWithValues: h.frames.map { ($0.id, CountingArtwork()) })
        h.engine.pageArtwork = { arts[$0] }
        show(h, pages: [0])
        try await waitUntil { h.engine.artworkRasters.count == 3 }
        #expect(h.engine.pageViews.count == 1)
        #expect(arts.values.allSatisfy { $0.draws == 1 })
        show(h, pages: [1], y: 866)
        #expect(h.engine.pageViews[h.frames[1].id]?.artworkLayer?.hasImage == true, "the flip is instant")
    }

    /// Past the bitmap's cap the visible part of the page renders at screen resolution into the detail,
    /// with a margin a short scroll stays inside; a long scroll re-renders it; a zoom the bitmap can
    /// serve clears it once that bitmap is on screen.
    @Test func deepZoomRendersTheVisiblePartAsDetail() async throws {
        let h = Harness()
        let id = h.frames[0].id
        let art = CountingArtwork()
        h.engine.maximumRasterDimension = 600 // caps A4 at 0.71 px/pt: every zoom is "deep"
        h.engine.pageArtwork = { $0 == id ? art : nil } // (prefetches at the cap in force now)
        let window = CGSize(width: 300, height: 300) // a 300 pt window onto the page
        show(h, pages: [0], size: window)
        let view = try #require(h.engine.pageViews[id])
        let layer = try #require(view.artworkLayer)
        try await waitUntil { layer.shownDetail != nil && layer.shownKey != nil }
        let detail = try #require(layer.shownDetail)
        #expect(detail.pixelScale == max(h.engine.screenScale, 1))
        #expect(detail.rect == CGRect(x: 0, y: 0, width: 330, height: 330), "the window plus 10 % a side, clamped to the page")
        #expect(layer.shownKey?.pixelScale ?? 1 < 1)
        let draws = art.draws

        show(h, pages: [0], y: 20, size: window)
        try await Task.sleep(for: .milliseconds(30))
        #expect(layer.shownDetail == detail && art.draws == draws, "inside the margin: nothing re-renders")

        show(h, pages: [0], y: 500, size: window)
        try await waitUntil { layer.shownDetail != detail }
        #expect(layer.shownDetail?.rect == CGRect(x: 0, y: 470, width: 330, height: 360))

        h.engine.maximumRasterDimension = 4096
        show(h, pages: [0], y: 500, size: window)
        #expect(layer.shownDetail != nil, "kept until the sharper bitmap lands")
        try await waitUntil { layer.shownDetail == nil }
        #expect(layer.shownKey?.pixelScale == max(h.engine.screenScale, 1))
    }

    /// The renderer draws page space y-down into the bitmap: the artwork's top-left square lands at the
    /// top-left, and a detail of a lower rect shows the part under it.
    @Test func rendererKeepsPageOrientation() throws {
        let art = CountingArtwork()
        let size = CGSize(width: 100, height: 200)
        let whole = try #require(ArtworkLayer.renderImage(art, size: size, pixelScale: 1))
        #expect(whole.width == 100 && whole.height == 200)
        #expect(Self.isRed(whole, x: 10, y: 10) && !Self.isRed(whole, x: 90, y: 190) && !Self.isRed(whole, x: 10, y: 150))
        let detail = try #require(ArtworkLayer.render(
            art,
            rect: CGRect(x: 0, y: 80, width: 100, height: 40),
            pageSize: size,
            pixelScale: 2
        ))
        #expect(detail.width == 200 && detail.height == 80)
        #expect(Self.isRed(detail, x: 10, y: 10), "page y 85: inside the square")
        #expect(!Self.isRed(detail, x: 10, y: 70), "page y 115: below it")
        #expect(!Self.isRed(detail, x: 150, y: 10), "page x 75: right of it")
    }

    private static func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let offset = y * image.bytesPerRow + x * 4
        // Little-endian ARGB: B G R A in memory.
        return bytes[offset + 2] > 200 && bytes[offset + 1] < 50 && bytes[offset] < 50
    }

    /// Mid-pinch nothing is asked of the detail; the memory warning empties the cache but not the screen.
    @Test func zoomingDefersDetailAndMemoryWarningKeepsTheScreen() async throws {
        let h = Harness()
        let id = h.frames[0].id
        let art = CountingArtwork()
        h.engine.maximumRasterDimension = 600
        h.engine.pageArtwork = { $0 == id ? art : nil }
        h.engine.setViewport(Viewport(contentOffset: .zero, zoomScale: 1, size: h.viewSize, pages: [h.frames[0]], isZooming: true))
        let layer = try #require(h.engine.pageViews[id]?.artworkLayer)
        try await waitUntil { layer.shownKey != nil }
        #expect(layer.requestedDetail == nil && layer.shownDetail == nil)
        h.engine.didReceiveMemoryWarning()
        #expect(h.engine.artworkRasters.isEmpty)
        #expect(layer.hasImage, "the page keeps what it shows")
    }
}
