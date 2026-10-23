import CoreGraphics
import InkModel
import Metal
import Perf

/// What a plan depends on: re-planning is skipped while it's unchanged and no tile landed.
struct PlanKey: Equatable {
    struct Page: Equatable {
        var id: PageID?
        var viewRect: CGRect
        var buffers: ObjectIdentifier?
        var isVisible: Bool
        var background: BackgroundUniforms
    }

    var width: Int
    var height: Int
    var bucket: ZoomBucket
    var pages: [Page]

    init(_ scene: ContentScene, bucket: ZoomBucket) {
        width = scene.pixelWidth
        height = scene.pixelHeight
        self.bucket = bucket
        pages = scene.pages.map {
            Page(
                id: $0.id,
                viewRect: $0.viewRect,
                buffers: $0.buffers.map(ObjectIdentifier.init),
                isVisible: $0.isVisible,
                background: $0.background
            )
        }
    }
}

extension TiledContentRenderer {
    /// A tile to render, in priority order (smaller first).
    private struct Want {
        var key: TileKey
        var priority: CGFloat
        var page: Int
    }

    /// Placement of one page in the frame.
    private struct Placement {
        var page: ScenePage
        var id: PageID
        var scene: ContentScene
        var grid: TileGrid

        /// `rect` (view pt) in page space.
        func pageRect(_ rect: CGRect) -> CGRect {
            let z = scene.zoomScale
            return CGRect(
                x: (rect.minX - page.viewRect.minX) / z,
                y: (rect.minY - page.viewRect.minY) / z,
                width: rect.width / z,
                height: rect.height / z
            )
        }

        /// `rect` (page space) in view points.
        func viewRect(_ rect: CGRect) -> CGRect {
            let z = scene.zoomScale
            return CGRect(
                x: page.viewRect.minX + rect.minX * z,
                y: page.viewRect.minY + rect.minY * z,
                width: rect.width * z,
                height: rect.height * z
            )
        }

        /// Draws `region` (page space) from a texture covering `source` (page space).
        func quad(_ region: CGRect, source: CGRect) -> TileQuad {
            let v = viewRect(region)
            let ppp = scene.pixelsPerPoint
            let w = CGFloat(scene.pixelWidth)
            let h = CGFloat(scene.pixelHeight)
            func clip(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
                SIMD2(Float(x * ppp / w * 2 - 1), Float(1 - y * ppp / h * 2))
            }
            let a = clip(v.minX, v.minY)
            let b = clip(v.maxX, v.maxY)
            let u0 = (region.minX - source.minX) / source.width
            let v0 = (region.minY - source.minY) / source.height
            let u1 = (region.maxX - source.minX) / source.width
            let v1 = (region.maxY - source.minY) / source.height
            return TileQuad(dst: SIMD4(a.x, a.y, b.x, b.y), uv: SIMD4(Float(u0), Float(v0), Float(u1), Float(v1)))
        }

        /// Distance (view pt) from the view center to the center of `rect` (page space).
        func distanceFromCenter(_ rect: CGRect) -> CGFloat {
            let v = viewRect(rect)
            return hypot(v.midX - scene.pointSize.width / 2, v.midY - scene.pointSize.height / 2)
        }
    }

    /// Builds the draw list for `scene` and queues the tiles it lacks (see the type's doc comment).
    func plan(_ scene: ContentScene, bucket: ZoomBucket) {
        guard let grid else { return }
        stats.plans += 1
        targetBucket = bucket
        var list = DrawList(width: scene.pixelWidth, height: scene.pixelHeight)
        var protected = Set<TileKey>()
        var wanted: [Want] = []
        var visible: [(key: TileKey, priority: CGFloat)] = []
        var unsettled = Set<PageID>()
        let view = CGRect(origin: .zero, size: scene.pointSize)

        for (i, page) in scene.pages.enumerated() where page.isVisible {
            guard let id = page.id else { continue }
            let at = Placement(page: page, id: id, scene: scene, grid: grid)
            let bounds = CGRect(origin: .zero, size: page.size)
            let keys = grid.keys(id, bucket, covering: at.pageRect(view), pageSize: page.size)
            publishStaged(page: id, visible: keys)
            for key in keys {
                protected.insert(key)
                let rect = grid.rect(of: key)
                let priority = at.distanceFromCenter(rect)
                visible.append((key, priority))
                if let entry = cache[key] {
                    cache.touch(key)
                    list.tiles.append(TileDraw(texture: entry.value, quad: at.quad(rect.intersection(bounds), source: rect)))
                    if entry.isStale {
                        unsettled.insert(id)
                        if needsRender(key) {
                            wanted.append(Want(key: key, priority: priority, page: i))
                        }
                    }
                } else {
                    unsettled.insert(id)
                    wanted.append(Want(key: key, priority: priority, page: i))
                    drawFallback(rect.intersection(bounds), at, bucket: bucket, into: &list, protecting: &protected)
                }
            }
        }
        let shown = Set(scene.pages.filter(\.isVisible).compactMap(\.id))
        for page in Set(staged.keys.map(\.page)) where !shown.contains(page) {
            publishStaged(page: page, visible: [])
        }
        wanted += prefetch(scene, bucket: bucket, grid: grid, protecting: &protected)
        draws = list
        self.unsettled = unsettled
        visibleKeys = visible.sorted { $0.priority < $1.priority }.map(\.key)
        planWasComplete = wanted.isEmpty && staged.isEmpty
        schedule(wanted, scene: scene, grid: grid, protecting: protected)
    }

    /// Prefetch: tiles of every page in the scene (visible ± 1) within ``prefetchMargin`` of the view.
    private func prefetch(_ scene: ContentScene, bucket: ZoomBucket, grid: TileGrid, protecting protected: inout Set<TileKey>) -> [Want] {
        let view = CGRect(origin: .zero, size: scene.pointSize)
        let margin = Self.prefetchMargin
        let area = view.insetBy(dx: -view.width * margin.width, dy: -view.height * margin.height)
        var wanted: [Want] = []
        for (i, page) in scene.pages.enumerated() {
            guard let id = page.id, page.buffers != nil else { continue }
            let at = Placement(page: page, id: id, scene: scene, grid: grid)
            for key in grid.keys(id, bucket, covering: at.pageRect(area), pageSize: page.size) where !protected.contains(key) {
                protected.insert(key)
                cache.touch(key)
                guard needsRender(key) else { continue }
                // Behind every visible tile, nearest first.
                wanted.append(Want(key: key, priority: 1e6 + at.distanceFromCenter(grid.rect(of: key)), page: i))
            }
        }
        return wanted
    }

    /// Draws a missing tile's `region`: the nearest bucket whose cached tiles cover all of it, else the
    /// page thumbnail, else paper (template, no ink).
    private func drawFallback(
        _ region: CGRect,
        _ at: Placement,
        bucket: ZoomBucket,
        into list: inout DrawList,
        protecting protected: inout Set<TileKey>
    ) {
        list.fallbacks += 1
        let grid = at.grid
        for other in bucket.fallbacks {
            let keys = grid.keys(at.id, other, covering: region, pageSize: at.page.size)
            let entries = keys.compactMap { key in cache[key].map { (key, $0.value) } }
            guard !keys.isEmpty, entries.count == keys.count else { continue }
            for (key, texture) in entries {
                cache.touch(key)
                protected.insert(key)
                let rect = grid.rect(of: key)
                list.tiles.append(TileDraw(texture: texture, quad: at.quad(region.intersection(rect), source: rect)))
            }
            stats.fallbackBucket += 1
            return
        }
        if let thumbnail = thumbnails[at.id] {
            list.tiles.append(TileDraw(texture: thumbnail, quad: at.quad(region, source: CGRect(origin: .zero, size: at.page.size))))
            stats.fallbackThumbnail += 1
            return
        }
        let scene = at.scene
        if let scissor = SceneEncoder.scissor(
            at.viewRect(region),
            pixelsPerPoint: scene.pixelsPerPoint,
            targetWidth: scene.pixelWidth,
            targetHeight: scene.pixelHeight
        ) {
            list.papers.append((at.page, scissor))
        }
        stats.fallbackPaper += 1
    }

    /// Missing, or stale without a current re-render waiting in staging.
    private func needsRender(_ key: TileKey) -> Bool {
        guard let entry = cache[key] else { return true }
        return entry.isStale && staged[key]?.isStale != false
    }

    /// Swaps in `page`'s staged re-renders once none of its `visible` stale tiles still lacks one.
    private func publishStaged(page: PageID, visible: [TileKey]) {
        guard !visible.contains(where: { cache[$0]?.isStale == true && staged[$0] == nil }) else { return }
        for key in staged.keys where key.page == page {
            guard let entry = staged.removeValue(forKey: key) else { continue }
            if let old = cache.insert(key, entry.texture, bytes: pool.tileBytes, isStale: entry.isStale) {
                retiring.append(old)
            }
        }
    }

    /// Evicts what the wanted tiles need (never `protected` ones) and queues as many as fit the budget.
    private func schedule(_ wanted: [Want], scene: ContentScene, grid: TileGrid, protecting protected: Set<TileKey>) {
        let budget = effectiveBudget()
        pool.capacity = budget
        let tileBytes = pool.tileBytes
        let started = renderer.startedKeys
        let renderable = wanted
            .filter { !started.contains($0.key) && scene.pages[$0.page].buffers != nil }
            .sorted { $0.priority < $1.priority }
        let reserved = (staged.count + started.count) * tileBytes
        let room = budget - reserved - renderable.count * tileBytes
        if cache.bytes > room {
            retiring += cache.evict(toFit: max(room, 0), protecting: protected)
        }
        let fits = max((budget - reserved - cache.bytes) / tileBytes, 0)
        let jobs = renderable.prefix(fits).compactMap { want -> TileRenderer.Job? in
            let page = scene.pages[want.page]
            guard let buffers = page.buffers else { return nil }
            return TileRenderer.Job(
                key: want.key,
                generation: generation,
                buffers: buffers,
                background: page.background,
                pageSize: page.size,
                grid: grid,
                blend: HighlightBlend(buffers.theme)
            )
        }
        renderer.submit(Array(jobs))
    }

    // MARK: HUD

    func registerGauges() {
        PerfHUD.register(gauge: PerfGauge(id: "ink.tiles", label: "tiles") { [weak self] in
            guard let self else { return "–" }
            return String(
                format: "%d · %.0f MB (pool %.0f / %.0f)",
                cache.count,
                Double(cache.bytes) / 1_048_576,
                Double(pool.allocatedBytes) / 1_048_576,
                Double(effectiveBudget()) / 1_048_576
            )
        })
        PerfHUD.register(gauge: PerfGauge(id: "ink.tiles.queue", label: "tile queue") { [weak self] in
            guard let self else { return "–" }
            let depth = renderer.depth
            return "\(depth.queued) queued · \(depth.started) on GPU"
        })
        PerfHUD.register(gauge: PerfGauge(id: "ink.tiles.fallback", label: "tile fallback") { [weak self] in
            guard let self else { return "–" }
            return "\(draws.fallbacks) now · \(stats.framesWithFallback) frames"
        })
    }
}
