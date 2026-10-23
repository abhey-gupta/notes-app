import CoreGraphics
@testable import InkEnginePencilKit
import InkModel
import Testing

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

    private func key(rev: UInt64 = 1) -> PageLayerView.InkKey {
        PageLayerView.InkKey(rev: rev, theme: .white, pixelScale: 2, strokeCount: 1)
    }

    @Test func hitsOnlyForTheSameKey() throws {
        let cache = InkRasterCache(budget: 1 << 20)
        let page = PageID()
        try cache.insert(image(), for: page, key: key())
        #expect(cache.image(for: page, key: key()) != nil)
        #expect(cache.image(for: page, key: key(rev: 2)) == nil, "edited page re-renders")
        try cache.insert(image(), for: page, key: key(rev: 2))
        #expect(cache.count == 1 && cache.bytes == 1024, "one raster per page")
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
