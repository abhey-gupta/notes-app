import CoreGraphics
@testable import InkEnginePencilKit
import InkModel
import Testing

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct InkRasterCacheTests {
    /// 16 × 16 RGBA: 1 KiB.
    private func image() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private func key(rev: UInt64 = 1, scale: CGFloat = 2) -> PageLayerView.InkKey {
        PageLayerView.InkKey(rev: rev, theme: .white, pixelScale: scale, strokeCount: 1, pendingCount: 0)
    }

    @Test func hitsOnlyForTheSameKey() throws {
        let cache = InkRasterCache(budget: 1 << 20)
        let page = PageID()
        try cache.insert(image(), for: page, key: key())
        #expect(cache.image(for: page, key: key()) != nil)
        #expect(cache.image(for: page, key: key(rev: 2)) == nil, "edited page re-renders")
        #expect(cache.image(for: page, key: key(scale: 4)) == nil, "another bucket renders")
    }

    /// An edit invalidates the page's rasters: the new content replaces every bucket of the old one.
    @Test func newContentDropsThePagesOldRasters() throws {
        let cache = InkRasterCache(budget: 1 << 20)
        let page = PageID()
        try cache.insert(image(), for: page, key: key(scale: 2))
        try cache.insert(image(), for: page, key: key(scale: 4))
        #expect(cache.count == 2 && cache.bytes == 2048, "two buckets of one content")
        try cache.insert(image(), for: page, key: key(rev: 2))
        #expect(cache.count == 1 && cache.bytes == 1024, "one raster of the new content")
        #expect(cache.image(for: page, key: key(scale: 4)) == nil)
    }

    /// While a zoom's bucket renders, the same content at the nearest bucket stands in (scaled).
    @Test func nearestBucketOfTheSameContent() throws {
        let cache = InkRasterCache(budget: 1 << 20)
        let page = PageID()
        let one = try image(), four = try image()
        cache.insert(one, for: page, key: key(scale: 1))
        cache.insert(four, for: page, key: key(scale: 4))
        #expect(cache.nearest(for: page, content: key().content, pixelScale: 2, size: .zero) === one, "ties go to the lower bucket")
        #expect(cache.nearest(for: page, content: key().content, pixelScale: 3, size: .zero) === four)
        #expect(
            cache.nearest(for: page, content: key(rev: 2).content, pixelScale: 2, size: .zero) == nil,
            "other content is not the same ink"
        )
        #expect(cache.latestImage(for: page, size: .zero) === four, "any content: the newest raster")
        let widened = CGSize(width: 800, height: 842)
        #expect(
            cache.nearest(for: page, content: key().content, pixelScale: 2, size: widened) == nil,
            "a raster of another page size never stands in (#129)"
        )
        #expect(cache.latestImage(for: page, size: widened) == nil)
    }

    @Test func thumbnailsShareTheBudget() throws {
        let cache = InkRasterCache(budget: 2048)
        let page = PageID()
        let thumb = try image()
        cache.insertThumbnail(thumb, for: page)
        try cache.insert(image(), for: page, key: key())
        #expect(cache.thumbnail(for: page) === thumb)
        #expect(cache.latestImage(for: page, size: .zero) !== thumb, "a thumbnail is not a raster")
        try cache.insert(image(), for: PageID(), key: key())
        #expect(cache.thumbnail(for: page) != nil, "touched: still the most recently used")
        #expect(cache.image(for: page, key: key()) == nil, "the page's raster was the oldest")
        cache.remove(page)
        #expect(cache.thumbnail(for: page) == nil)
    }

    @Test func evictsLeastRecentlyUsedOverBudget() throws {
        let cache = InkRasterCache(budget: 2048)
        let (a, b, c) = (PageID(), PageID(), PageID())
        try cache.insert(image(), for: a, key: key())
        try cache.insert(image(), for: b, key: key())
        _ = cache.image(for: a, key: key())
        try cache.insert(image(), for: c, key: key())
        #expect(cache.image(for: b, key: key()) == nil)
        #expect(cache.image(for: a, key: key()) != nil)
        #expect(cache.image(for: c, key: key()) != nil)
        #expect(cache.bytes == 2048)
        cache.removeAll()
        #expect(cache.isEmpty && cache.bytes == 0)
    }
}
