import CoreGraphics
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkModel
import Metal
import Testing

struct TileMathTests {
    @Test(arguments: [
        (CGFloat(0.25), ZoomBucket.half), (0.5, .half), (0.55, .half), (0.56, .one), (1, .one), (1.1, .one),
        (1.11, .two), (2, .two), (2.2, .two), (2.21, .four), (4, .four), (8, .four),
    ])
    func bucketForZoom(_ zoom: CGFloat, _ bucket: ZoomBucket) {
        #expect(ZoomBucket.forZoom(zoom) == bucket)
    }

    @Test func fallbacksGoNearestFirstSharperOnTies() {
        #expect(ZoomBucket.one.fallbacks == [.two, .half, .four])
        #expect(ZoomBucket.two.fallbacks == [.four, .one, .half])
        #expect(ZoomBucket.half.fallbacks == [.one, .two, .four])
        #expect(ZoomBucket.four.fallbacks == [.two, .one, .half])
    }

    @Test func tileSideAndPageDimensions() {
        let grid = TileGrid(pixelsPerPoint: 2)
        #expect(grid.side(.half) == 512)
        #expect(grid.side(.one) == 256)
        #expect(grid.side(.two) == 128)
        #expect(grid.side(.four) == 64)
        let a4 = Notebook.a4Portrait
        #expect(grid.dimensions(a4, .one) == (3, 4))
        #expect(grid.dimensions(a4, .four) == (10, 14))
        #expect(TileGrid(pixelsPerPoint: 3).dimensions(a4, .one) == (4, 5))
    }

    @Test func keysCoverTheRectClippedToThePage() {
        let grid = TileGrid(pixelsPerPoint: 2)
        let page = RenderFixtures.pageID(1)
        let a4 = Notebook.a4Portrait
        func cells(_ rect: CGRect, _ bucket: ZoomBucket = .one) -> [[Int32]] {
            grid.keys(page, bucket, covering: rect, pageSize: a4).map { [$0.col, $0.row] }
        }
        #expect(cells(CGRect(x: 250, y: 250, width: 20, height: 20)) == [[0, 0], [1, 0], [0, 1], [1, 1]])
        #expect(cells(CGRect(x: 0, y: 0, width: 256, height: 256)) == [[0, 0]]) // edges don't spill
        #expect(cells(CGRect(x: -100, y: 800, width: 2000, height: 500)) == [[0, 3], [1, 3], [2, 3]])
        #expect(cells(CGRect(x: 600, y: 0, width: 10, height: 10)).isEmpty) // right of the page
        #expect(cells(CGRect(origin: .zero, size: a4)).count == 12)
        let key = TileKey(page: page, bucket: .two, col: 3, row: 1)
        #expect(grid.rect(of: key) == CGRect(x: 384, y: 128, width: 128, height: 128))
    }

    @Test func budgetScalesWithPhysicalMemory() {
        let gb = UInt64(1) << 30
        #expect(TileBudget.bytes(physicalMemory: 8 * gb) == 256 << 20)
        #expect(TileBudget.bytes(physicalMemory: 6 * gb) == 192 << 20)
        #expect(TileBudget.bytes(physicalMemory: 2 * gb) == 96 << 20)
        #expect(TileBudget.bytes(physicalMemory: 16 * gb) == 320 << 20)
    }
}

struct TileCacheTests {
    let page = RenderFixtures.pageID(1)
    let other = RenderFixtures.pageID(2)

    func key(_ col: Int32, _ row: Int32 = 0, _ bucket: ZoomBucket = .one, page: PageID? = nil) -> TileKey {
        TileKey(page: page ?? self.page, bucket: bucket, col: col, row: row)
    }

    @Test func evictsLeastRecentlyUsedUntilUnderBudget() {
        var cache = TileCache<Int>()
        for i in 0 ..< 5 {
            cache.insert(key(Int32(i)), i, bytes: 10)
        }
        #expect(cache.bytes == 50)
        cache.touch(key(0))
        let evicted = cache.evict(toFit: 30, protecting: [])
        #expect(evicted.sorted() == [1, 2])
        #expect(cache.bytes == 30)
        #expect(Set(cache.entries.keys) == [key(0), key(3), key(4)])
        #expect(cache.evict(toFit: 30, protecting: []).isEmpty) // already fits
    }

    @Test func neverEvictsProtectedTiles() {
        var cache = TileCache<Int>()
        for i in 0 ..< 4 {
            cache.insert(key(Int32(i)), i, bytes: 10)
        }
        let evicted = cache.evict(toFit: 0, protecting: [key(0), key(1)])
        #expect(evicted.sorted() == [2, 3])
        #expect(cache.bytes == 20)
    }

    @Test func replacingAnEntryKeepsBytesExact() {
        var cache = TileCache<Int>()
        cache.insert(key(0), 1, bytes: 10)
        #expect(cache.insert(key(0), 2, bytes: 12, isStale: true) == 1)
        #expect(cache.bytes == 12)
        #expect(cache[key(0)]?.isStale == true)
        #expect(cache.remove(key(0)) == 2)
        #expect(cache.bytes == 0)
    }

    @Test func invalidationStalesTargetBucketAndEvictsOthers() {
        let grid = TileGrid(pixelsPerPoint: 2)
        var cache = TileCache<Int>()
        cache.insert(key(0), 0, bytes: 1) // 0...256
        cache.insert(key(1), 1, bytes: 1) // 256...512
        cache.insert(key(0, 0, .half), 2, bytes: 1) // 0...512
        cache.insert(key(1, 0, .two), 3, bytes: 1) // 128...256
        cache.insert(key(0, page: other), 4, bytes: 1)
        let result = cache.invalidate(page: page, rect: CGRect(x: 300, y: 10, width: 20, height: 20), keep: .one, grid: grid)
        #expect(result.stale == [key(1)])
        #expect(result.evicted == [2])
        #expect(cache[key(0)]?.isStale == false)
        #expect(cache[key(1, 0, .two)] != nil) // doesn't intersect
        let all = cache.invalidate(page: page, rect: nil, keep: .one, grid: grid)
        #expect(Set(all.stale) == [key(0), key(1)])
        #expect(all.evicted == [3])
        #expect(cache[key(0, page: other)]?.isStale == false)
    }
}

@MainActor
struct StrokeSelectionTests {
    func build(_ strokes: [Stroke]) throws -> PageBuffers {
        let gpu = try #require(GPUContext.shared)
        let snapshot = PageSnapshot(page: Page(id: RenderFixtures.pageID(3), strokes: strokes), size: RenderFixtures.pageSize)
        let input = PageBuildInput(snapshot: snapshot, theme: .white, palette: FixturePalette(), fringe: 1, cached: [:])
        return PageBuilder.buildNow(input, device: gpu.device).buffers
    }

    @Test func selectsOnlyStrokesOverlappingTheRectMergingNeighbours() throws {
        let strokes = [
            RenderFixtures.line(1, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 20)),
            RenderFixtures.line(2, from: CGPoint(x: 20, y: 400), to: CGPoint(x: 100, y: 400)),
            RenderFixtures.line(3, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 100, y: 30)),
            RenderFixtures.line(4, from: CGPoint(x: 20, y: 40), to: CGPoint(x: 100, y: 40), tool: .highlighter, width: 12),
            RenderFixtures.line(5, from: CGPoint(x: 20, y: 410), to: CGPoint(x: 100, y: 410), tool: .highlighter, width: 12),
        ]
        let buffers = try build(strokes)
        let top = buffers.selection(in: CGRect(x: 0, y: 0, width: 200, height: 60))
        #expect(top.ink == [buffers.strokeRanges[0], buffers.strokeRanges[2]])
        #expect(top.highlightGroups == [[buffers.strokeRanges[3]]])
        let bottom = buffers.selection(in: CGRect(x: 0, y: 380, width: 200, height: 60))
        #expect(bottom.ink == [buffers.strokeRanges[1]])
        #expect(bottom.highlightGroups == [[buffers.strokeRanges[4]]])
        // Everything: adjacent strips merge back into the page's ranges.
        let all = buffers.selection(in: CGRect(origin: .zero, size: RenderFixtures.pageSize))
        #expect(all == buffers.all)
        #expect(buffers.selection(in: CGRect(x: 300, y: 600, width: 10, height: 10)).isEmpty)
    }
}

@MainActor
struct PageDiffTests {
    func build(_ page: Page, theme: PaperTheme = .white) throws -> PageBuffers {
        let gpu = try #require(GPUContext.shared)
        let input = PageBuildInput(
            snapshot: PageSnapshot(page: page, size: RenderFixtures.pageSize),
            theme: theme,
            palette: FixturePalette(),
            fringe: 1,
            cached: [:]
        )
        return PageBuilder.buildNow(input, device: gpu.device).buffers
    }

    @Test func dirtyRectCoversExactlyTheChangedStrokes() throws {
        let a = RenderFixtures.line(1, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 20))
        let b = RenderFixtures.line(2, from: CGPoint(x: 300, y: 500), to: CGPoint(x: 400, y: 520))
        let page = Page(id: RenderFixtures.pageID(4), strokes: [a])
        let old = try build(page)
        #expect(try PageDiff.dirtyRect(from: old, to: build(page)) == .null)

        let added = try build(page.applying(page.addEdit([b])))
        #expect(PageDiff.dirtyRect(from: old, to: added) == added.bounds(of: b.id))

        let recolored = try build(page.applying(page.recolorEdit([a.id], to: .semantic(.red))))
        #expect(PageDiff.dirtyRect(from: old, to: recolored) == old.bounds(of: a.id))

        let removed = try build(page.applying(page.removeEdit([a.id])))
        #expect(PageDiff.dirtyRect(from: old, to: removed) == old.bounds(of: a.id))

        #expect(try PageDiff.dirtyRect(from: old, to: build(page, theme: .night)) == nil)
    }
}
