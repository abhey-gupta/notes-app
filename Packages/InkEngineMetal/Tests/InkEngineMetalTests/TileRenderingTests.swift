import CoreGraphics
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkModel
import Metal
import Testing

/// Fixture pages loaded into an engine (for its builds and scenes); renderers under test get the
/// engine's scenes directly.
@MainActor
struct ContentHarness {
    let engine: MetalInkEngine
    let frames: [VisiblePage]

    init(pages: Int = 3, theme: PaperTheme = .white) async throws {
        let fixture = FixturePages.make(pages)
        engine = try #require(MetalInkEngine(palette: FixturePalette(), contentMode: .viewportComposite))
        engine.setTheme(theme)
        engine.setPages(fixture.snapshots)
        frames = fixture.frames
        await engine.waitForBuilds()
    }

    /// The scene a 1024 × 1366 pt, 2× view shows at `offset` and `zoom`.
    func scene(x: CGFloat = 0, y: CGFloat, zoom: CGFloat = 1) -> ContentScene {
        let size = CGSize(width: 1024, height: 1366)
        engine.setViewport(Viewport(contentOffset: CGPoint(x: x, y: y), zoomScale: zoom, size: size, pages: frames))
        return engine.makeScene(ContentCapture.target(size))
    }
}

@MainActor
struct TileEquivalenceTests {
    /// Tiles composited 1:1 (zoom on a bucket, pixel-aligned offsets) must match the viewport composite.
    @Test(arguments: [
        (CGFloat(1), CGFloat(0), CGFloat(900), PaperTheme.white),
        (2, 300, 1900, .white),
        (0.5, 0, 0, .white),
        (1, 0, 900, .night),
    ])
    func tiledCompositeMatchesViewportComposite(zoom: CGFloat, x: CGFloat, y: CGFloat, theme: PaperTheme) async throws {
        let h = try await ContentHarness(theme: theme)
        let scene = h.scene(x: x, y: y, zoom: zoom)
        let tiles = try ContentCapture.tiles()
        try await ContentCapture.settle(tiles, scene)
        let composite = try ViewportCompositeRenderer(gpu: ContentCapture.gpu)
        let expected = try await ContentCapture.capture(composite, scene)
        let actual = try await ContentCapture.capture(tiles, scene)
        let diff = try #require(Golden.difference(actual, expected))
        PerfReport.append("equivalence zoom \(zoom) \(theme): \(diff), \(tiles.cache.count) tiles")
        #expect(diff.differingFraction <= 0.0005, "\(diff)")
        #expect(diff.meanDelta <= 0.25, "\(diff)")
        #expect(tiles.draws.fallbacks == 0)
    }
}

@MainActor
struct TileInvalidationTests {
    @Test func invalidationReRendersOnlyIntersectingTiles() async throws {
        let h = try await ContentHarness()
        let scene = h.scene(y: 900)
        let tiles = try ContentCapture.tiles()
        try await ContentCapture.settle(tiles, scene)
        let grid = try #require(tiles.grid)
        let page = h.frames[1].id
        // Straddles a tile corner at bucket 1 (256 pt tiles at 2×).
        let rect = CGRect(x: 240, y: 500, width: 40, height: 30)
        let expected = Set(tiles.cache.entries.keys.filter { $0.page == page && $0.bucket == .one && grid.rect(of: $0).intersects(rect) })
        #expect(expected.count == 4)
        let before = try await ContentCapture.capture(tiles, scene)
        tiles.renderLog = []
        tiles.invalidate(page: page, rect: rect)
        try await ContentCapture.settle(tiles, scene)
        #expect(tiles.renderLog?.count == expected.count)
        #expect(Set(tiles.renderLog ?? []) == expected)
        // Same content: the re-rendered tiles are identical.
        let after = try await ContentCapture.capture(tiles, scene)
        #expect(Golden.difference(before, after)?.differingFraction == 0)
    }

    @Test func committedStrokeReRendersAtMostFourTiles() async throws {
        var h = try Harness()
        try await h.engine.settle()
        let tiles = try #require(h.engine.tiles)
        let side = try #require(tiles.grid).side(.one)
        tiles.renderLog = []
        h.engine.setTool(ToolConfiguration(tool: .pen(.fountain), color: .primary, width: 3))
        h.recorder.echo = { [engine = h.engine] stroke, page in
            guard let snapshot = engine.snapshots[page] else { return }
            engine.apply(snapshot.page.addEdit([stroke]), to: page)
        }
        // A handwritten word (~60 × 20 pt) straddling a tile corner on page 2 (page y = view y + 34):
        // the worst common case.
        let corner = CGPoint(x: side, y: side - 34)
        h.draw((0 ... 60).map { i in
            CGPoint(x: corner.x - 30 + CGFloat(i), y: corner.y - 10 + 10 * sin(CGFloat(i) / 4))
        })
        h.snapshots[1] = try #require(h.engine.snapshots[h.page2])
        try await h.engine.settle()
        let log = tiles.renderLog ?? []
        #expect(log.count >= 1 && log.count <= 4, "\(log)")
        #expect(log.allSatisfy { $0.page == h.page2 })
        #expect(h.engine.pending[h.page2]?.isEmpty != false)
    }

    @Test func themeChangeReRendersEveryResidentTile() async throws {
        let h = try Harness()
        try await h.engine.settle()
        let tiles = try #require(h.engine.tiles)
        let resident = Set(tiles.cache.entries.keys.filter { $0.bucket == tiles.targetBucket })
        #expect(!resident.isEmpty)
        tiles.renderLog = []
        h.engine.setTheme(.night)
        try await h.engine.settle()
        #expect(resident.isSubset(of: Set(tiles.renderLog ?? [])))
        #expect(tiles.cache.entries.values.allSatisfy { !$0.isStale })
    }
}

@MainActor
struct TileFallbackTests {
    @Test func missingTilesFallBackToTheNearestBucket() async throws {
        let h = try await ContentHarness()
        let tiles = try ContentCapture.tiles()
        try await ContentCapture.settle(tiles, h.scene(y: 900))
        let bucketOne = Set(tiles.cache.entries.filter { $0.key.bucket == .one }.map { ObjectIdentifier($0.value.value) })
        // Zoom to 2 around the same area: one prepare plans and queues bucket-2 tiles; none landed yet.
        let zoomed = h.scene(x: 200, y: 1900, zoom: 2)
        try ContentCapture.prepare(tiles, zoomed)
        #expect(tiles.targetBucket == .two)
        #expect(tiles.draws.fallbacks == tiles.visibleKeys.count)
        #expect(tiles.draws.papers.isEmpty)
        #expect(tiles.draws.tiles.allSatisfy { bucketOne.contains(ObjectIdentifier($0.texture)) })
        #expect(!tiles.isSettled(page: h.frames[1].id))
        try await ContentCapture.settle(tiles, zoomed)
        #expect(tiles.draws.fallbacks == 0)
        #expect(tiles.isSettled(page: h.frames[1].id))
    }

    @Test func pinchScalesTheCurrentBucketUntilTheGestureEnds() async throws {
        let h = try await ContentHarness()
        let tiles = try ContentCapture.tiles()
        try await ContentCapture.settle(tiles, h.scene(y: 900))
        tiles.beginZoomGesture()
        let rendered = tiles.renderCount
        for step in 1 ... 10 {
            let zoom = 1 + CGFloat(step) / 10
            try ContentCapture.prepare(tiles, h.scene(x: 100 * (zoom - 1), y: 900 * zoom, zoom: zoom))
            #expect(tiles.targetBucket == .one)
            #expect(tiles.draws.fallbacks == 0)
        }
        try await Task.sleep(for: .milliseconds(50))
        try ContentCapture.prepare(tiles, h.scene(x: 100, y: 1800, zoom: 2))
        #expect(tiles.renderCount - rendered < 10) // stray prefetch at most, no bucket-2 renders
        tiles.endZoomGesture()
        let final = h.scene(x: 100, y: 1800, zoom: 2)
        try ContentCapture.prepare(tiles, final)
        #expect(tiles.targetBucket == .two)
        try await ContentCapture.settle(tiles, final)
        #expect(tiles.cache.entries.keys.contains { $0.bucket == .two })
    }

    @Test func noTilesFallBackToTheThumbnail() async throws {
        let h = try await ContentHarness()
        let scene = h.scene(y: 900)
        let tiles = try ContentCapture.tiles(budget: 0) // nothing ever renders
        let device = try ContentCapture.gpu.device
        for page in scene.visiblePages {
            let id = try #require(page.id)
            let snapshot = try #require(h.engine.snapshots[id])
            let image = try #require(await h.engine.render(page: snapshot, size: CGSize(width: 150, height: 212), scale: 1))
            tiles.setThumbnail(ThumbnailTexture.make(image, device: device), for: id)
        }
        let before = tiles.stats.fallbackThumbnail
        try ContentCapture.prepare(tiles, scene)
        #expect(tiles.draws.papers.isEmpty)
        #expect(tiles.draws.tiles.count == tiles.visibleKeys.count)
        #expect(tiles.stats.fallbackThumbnail - before == tiles.visibleKeys.count)
        #expect(tiles.renderer.depth == (0, 0))
    }

    @Test func noTilesAndNoThumbnailFallBackToPaper() async throws {
        let h = try await ContentHarness()
        let scene = h.scene(y: 900)
        let tiles = try ContentCapture.tiles(budget: 0)
        let actual = try await ContentCapture.capture(tiles, scene)
        #expect(tiles.draws.tiles.isEmpty)
        #expect(tiles.draws.papers.count == tiles.visibleKeys.count)
        // Paper + template exactly as the composite draws a page without ink.
        var paperOnly = scene
        paperOnly.pages = scene.pages.map { page in
            var page = page
            page.buffers = nil
            return page
        }
        let expected = try await ContentCapture.capture(ViewportCompositeRenderer(gpu: ContentCapture.gpu), paperOnly)
        let diff = try #require(Golden.difference(actual, expected))
        #expect(diff.differingFraction == 0, "\(diff)")
    }
}

@MainActor
struct TileMemoryTests {
    @Test func memoryWarningHalvesTileMemoryWithoutVisualChange() async throws {
        let h = try await ContentHarness()
        let tiles = try ContentCapture.tiles()
        try await ContentCapture.settle(tiles, h.scene(x: 200, y: 1900, zoom: 2))
        let scene = h.scene(y: 900)
        try await ContentCapture.settle(tiles, scene)
        let before = tiles.pool.allocatedBytes
        let shown = try await ContentCapture.capture(tiles, scene)
        tiles.handleMemoryWarning()
        let after = tiles.pool.allocatedBytes
        PerfReport.append("memory warning: pool \(before >> 20) → \(after >> 20) MiB, \(tiles.cache.count) tiles kept")
        #expect(after * 2 <= before)
        // Visible tiles survive (compacted into a fresh heap): the very next frame is identical.
        let next = try await ContentCapture.capture(tiles, scene)
        #expect(Golden.difference(shown, next)?.differingFraction == 0)
        #expect(tiles.draws.fallbacks == 0)
        // Prefetch refills within the halved budget.
        try await ContentCapture.settle(tiles, scene)
        #expect(tiles.pool.allocatedBytes <= tiles.effectiveBudget())
        #expect(tiles.effectiveBudget() <= before / 2)
        let settled = try await ContentCapture.capture(tiles, scene)
        #expect(Golden.difference(shown, settled)?.differingFraction == 0)
    }

    @Test func staysWithinBudgetWhileScrolling() async throws {
        let h = try await ContentHarness(pages: 8)
        let tiles = try ContentCapture.tiles(budget: 48 << 20)
        var peak = 0
        var y: CGFloat = 0
        while y < 6 * 866 {
            let scene = h.scene(y: y)
            try ContentCapture.prepare(tiles, scene)
            try await Task.sleep(for: .milliseconds(4))
            peak = max(peak, tiles.pool.allocatedBytes)
            #expect(tiles.cache.bytes + tiles.staged.count * tiles.pool.tileBytes <= 48 << 20)
            y += 120
        }
        #expect(peak <= 48 << 20)
        #expect(tiles.renderCount > 0)
    }
}
