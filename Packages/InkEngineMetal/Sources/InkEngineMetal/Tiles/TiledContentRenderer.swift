import CoreGraphics
import Foundation
import InkModel
import Metal
import os
import Perf
import QuartzCore
import Synchronization
import UIKit

/// Committed content as cached page tiles (ARCHITECTURE.md §5.4).
///
/// **Per frame** (``prepare(_:commandBuffer:)``, main actor, never waits): collect finished tiles from
/// the ``TileRenderer``; if anything changed, plan: for each visible page, the tiles at the target
/// ``ZoomBucket`` that cover the view; draw each from the cache or, if missing, the fallback chain
/// (nearest bucket that fully covers it → page thumbnail → paper and template without ink), then queue
/// missing and stale tiles nearest the view center first, then prefetch tiles of resident pages
/// (``prefetchMargin``), within the byte budget. ``draw(in:)`` is one quad per tile region.
///
/// **Residency**: the engine's scene carries the visible pages ± 1 (off-screen ones only prefetch);
/// tiles of pages up to ± 3 age out of the LRU (``TileCache``), beyond that they go with the page's
/// buffers (``retainPages(_:)``); queued renders for tiles no longer wanted are dropped with the next
/// ``TileRenderer/submit(_:)``. Heaps whose textures are all free are released (``TexturePool/trim()``).
///
/// **Invalidation** is per page rect: intersecting tiles at the target bucket turn stale (still drawn)
/// and re-render; at other buckets they're evicted. Re-rendered tiles replacing stale ones are staged
/// and swapped in together once every stale tile visible on that page has its replacement, so a commit
/// or theme switch never shows a patchwork, and ``isSettled(page:)`` tells the engine when to stop
/// drawing pending strokes on top.
///
/// **Zoom**: during a pinch (``beginZoomGesture()``/``endZoomGesture()``, or inferred while the zoom
/// keeps changing, until it has been still for ``Configuration/zoomSettleDelay``) the bucket never gets
/// sharper than at gesture start: existing tiles are scaled on the GPU; zooming out may drop to a
/// coarser bucket (fewer pixels). The sharp bucket renders when the gesture ends.
///
/// **Memory**: LRU by bytes within ``Configuration/budget``; on a memory warning keeps only visible
/// tiles (≤ half the pool), compacts them into one heap and halves the budget for a while.
@MainActor
final class TiledContentRenderer: CommittedContentRenderer {
    struct Configuration {
        var budget = TileBudget.bytes()
        var zoomSettleDelay: TimeInterval = 0.15
        /// How long the halved budget holds after a memory warning.
        var memoryPressureDuration: TimeInterval = 30
        var registersGauges = true
        /// Off in tests: a real (simulator) warning would halve every live renderer's budget mid-test.
        var observesMemoryWarnings = true
    }

    /// Prefetch margin around the view, as a fraction of its size per side: mostly along the scroll axis.
    static let prefetchMargin = CGSize(width: 0.25, height: 0.75)

    struct Staged {
        var texture: any MTLTexture
        var isStale: Bool
    }

    struct Invalidation {
        var generation: Int
        var rect: CGRect?
    }

    struct TileDraw {
        var texture: any MTLTexture
        var quad: TileQuad
    }

    struct DrawList {
        var width = 0
        var height = 0
        var tiles: [TileDraw] = []
        var papers: [(page: ScenePage, scissor: MTLScissorRect)] = []
        /// Regions drawn from a fallback.
        var fallbacks = 0
    }

    let gpu: GPUContext
    let pool: TexturePool
    let renderer: TileRenderer
    var configuration: Configuration
    /// Asks the engine for a frame (tiles landed, zoom settled).
    var onNeedsFrame: (() -> Void)?

    var cache = TileCache<any MTLTexture>()
    var staged: [TileKey: Staged] = [:]
    var thumbnails: [PageID: any MTLTexture] = [:]
    /// Evicted or replaced textures, recycled once frames that may show them completed.
    var retiring: [any MTLTexture] = []
    private(set) var grid: TileGrid?
    var generation = 0
    var invalidations: [PageID: [Invalidation]] = [:]
    /// Results planned before this generation count as stale (the invalidation log was trimmed).
    var invalidationFloor = 0

    var draws = DrawList()
    var unsettled: Set<PageID> = []
    var needsPlan = true
    var lastPlanKey: PlanKey?
    /// Bucket of the last plan.
    var targetBucket: ZoomBucket?
    /// Visible target-bucket tiles of the last plan, nearest the center first.
    var visibleKeys: [TileKey] = []
    /// The last plan wanted nothing (every visible and prefetch tile current).
    var planWasComplete = false

    var gestureActive = false
    var usesExplicitGestures = false
    var frozenBucket: ZoomBucket?
    var lastZoom: CGFloat?
    var lastZoomChange: CFTimeInterval = -.infinity
    var settleTask: Task<Void, Never>?

    var pressureBudget: Int?
    var pressureUntil: CFTimeInterval = 0

    var stats = TileStats()
    private(set) var renderCount = 0
    /// Keys of tiles as they land, when non-`nil` (tests).
    var renderLog: [TileKey]?
    /// Main-thread CPU time of each ``prepare(_:commandBuffer:)`` (s; not wall time, so preemption on a
    /// loaded machine doesn't count), when non-`nil` (tests).
    var prepareTimes: [Double]?
    private var memoryObserver: (any NSObjectProtocol)?
    static let log = Logger(subsystem: "com.abhey.notespace", category: "ink.tiles")

    init?(gpu: GPUContext, configuration: Configuration = Configuration()) {
        let signal = TileSignal()
        let pool = TexturePool(device: gpu.device, capacity: configuration.budget)
        guard let renderer = TileRenderer(gpu: gpu, pool: pool, notify: { signal.fire() }) else { return nil }
        self.gpu = gpu
        self.pool = pool
        self.renderer = renderer
        self.configuration = configuration
        signal.setHandler { [weak self] in
            self?.needsPlan = true
            self?.onNeedsFrame?()
        }
        if configuration.observesMemoryWarnings {
            memoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMemoryWarning() }
            }
        }
        if configuration.registersGauges {
            registerGauges()
        }
    }

    isolated deinit {
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
        settleTask?.cancel()
        renderer.submit([])
    }

    // MARK: CommittedContentRenderer

    func invalidate(page: PageID, rect: CGRect?) {
        generation += 1
        invalidations[page, default: []].append(Invalidation(generation: generation, rect: rect))
        needsPlan = true
        if invalidations.values.reduce(0, { $0 + $1.count }) > 512 {
            invalidations.removeAll()
            generation += 1
            invalidationFloor = generation
        }
        guard let grid else { return }
        let result = cache.invalidate(page: page, rect: rect, keep: targetBucket, grid: grid)
        retiring += result.evicted
        for key in staged.keys where key.page == page && rect.map({ grid.rect(of: key).intersects($0) }) != false {
            staged[key]?.isStale = true
        }
    }

    func setNeedsDisplay() {
        needsPlan = true
    }

    @discardableResult
    func prepare(_ scene: ContentScene, commandBuffer _: any MTLCommandBuffer) -> Bool {
        guard scene.pixelWidth > 0, scene.pixelHeight > 0, scene.pixelsPerPoint > 0 else { return false }
        let start = prepareTimes == nil ? 0 : Self.threadCPUTime()
        defer {
            if prepareTimes != nil {
                prepareTimes?.append(Self.threadCPUTime() - start)
            }
        }
        stats.frames += 1
        updateGrid(TileGrid(pixelsPerPoint: scene.pixelsPerPoint))
        let landed = collectResults()
        let bucket = bucket(forZoom: scene.zoomScale, now: CACurrentMediaTime())
        let key = PlanKey(scene, bucket: bucket)
        if needsPlan || landed || key != lastPlanKey {
            needsPlan = false
            lastPlanKey = key
            plan(scene, bucket: bucket)
        }
        if draws.fallbacks > 0 {
            stats.framesWithFallback += 1
        }
        retireEvicted()
        if pool.freeCount >= 2 * TexturePool.heapTiles {
            pool.trim()
        }
        return false
    }

    func draw(in encoder: any MTLRenderCommandEncoder) {
        let full = MTLScissorRect(x: 0, y: 0, width: draws.width, height: draws.height)
        guard full.width > 0, full.height > 0 else { return }
        if !draws.papers.isEmpty {
            encoder.setRenderPipelineState(gpu.pipelines.background)
            for paper in draws.papers {
                SceneEncoder.drawBackground(paper.page, scissor: paper.scissor, encoder)
            }
        }
        encoder.setScissorRect(full)
        encoder.setRenderPipelineState(gpu.pipelines.tile)
        for tile in draws.tiles {
            var quad = tile.quad
            encoder.setVertexBytes(&quad, length: MemoryLayout<TileQuad>.stride, index: 0)
            encoder.setFragmentTexture(tile.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    func isSettled(page: PageID) -> Bool {
        !unsettled.contains(page)
    }

    /// CPU time consumed by the calling thread (s).
    private static func threadCPUTime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    // MARK: Hooks

    /// A page thumbnail (sRGB BGRA texture of the whole page), the fallback below tiles; `nil` clears.
    func setThumbnail(_ texture: (any MTLTexture)?, for page: PageID) {
        thumbnails[page] = texture
        needsPlan = true
    }

    /// Evicts tiles of pages not in `keep` (the engine's ± 3 page window: their buffers are gone too).
    func retainPages(_ keep: Set<PageID>) {
        retiring += cache.removeAll { keep.contains($0.page) }
        for key in staged.keys where !keep.contains(key.page) {
            if let entry = staged.removeValue(forKey: key) {
                retiring.append(entry.texture)
            }
        }
        needsPlan = true
    }

    /// Pinch began: keep scaling the current bucket instead of re-rendering at every zoom step.
    func beginZoomGesture() {
        usesExplicitGestures = true
        gestureActive = true
        frozenBucket = frozenBucket ?? targetBucket
    }

    /// Pinch ended: render the bucket for the final zoom.
    func endZoomGesture() {
        gestureActive = false
        frozenBucket = nil
        needsPlan = true
        onNeedsFrame?()
    }

    /// Everything visible and prefetched is current and nothing is rendering (tests).
    var isIdle: Bool {
        let depth = renderer.depth
        return depth.queued == 0 && depth.started == 0 && staged.isEmpty && planWasComplete && !needsPlan && frozenBucket == nil
    }

    // MARK: Results

    /// Moves finished renders into the cache (or staging). Returns whether any landed.
    private func collectResults() -> Bool {
        let results = renderer.takeResults()
        guard !results.isEmpty else { return false }
        for result in results {
            guard let texture = result.texture, grid != nil, pool.owns(texture) else { continue }
            let stale = isInvalidated(result.key, since: result.generation)
            renderCount += 1
            renderLog?.append(result.key)
            if cache[result.key]?.isStale == true {
                if let old = staged.updateValue(Staged(texture: texture, isStale: stale), forKey: result.key) {
                    retiring.append(old.texture)
                }
            } else if let old = cache.insert(result.key, texture, bytes: pool.tileBytes, isStale: stale) {
                retiring.append(old)
            }
        }
        let depth = renderer.depth
        if depth.queued == 0, depth.started == 0 {
            invalidations.removeAll()
        }
        return true
    }

    private func isInvalidated(_ key: TileKey, since planned: Int) -> Bool {
        guard planned >= invalidationFloor else { return true }
        guard let log = invalidations[key.page], let grid else { return false }
        let rect = grid.rect(of: key)
        return log.contains { $0.generation > planned && ($0.rect.map(rect.intersects) ?? true) }
    }

    /// A new screen scale invalidates every tile's geometry.
    private func updateGrid(_ new: TileGrid) {
        guard new != grid else { return }
        if grid != nil {
            retiring += cache.removeAll { _ in false }
            retiring += staged.values.map(\.texture)
            staged.removeAll()
            renderer.submit([])
            generation += 1
            invalidationFloor = generation
        }
        grid = new
        needsPlan = true
    }

    /// Recycles evicted textures after every frame committed so far (which may sample them) completed.
    private func retireEvicted() {
        guard !retiring.isEmpty else { return }
        let retired = Retired(textures: retiring)
        retiring.removeAll()
        guard let commandBuffer = gpu.frameQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "ink.tiles.retire"
        let pool = pool
        commandBuffer.addCompletedHandler { _ in pool.recycle(retired.textures) }
        commandBuffer.commit()
    }
}

/// Textures handed to a completion handler. `@unchecked Sendable`: nothing else uses them any more.
private struct Retired: @unchecked Sendable {
    var textures: [any MTLTexture]
}

/// Counters for the HUD and tests (cumulative).
struct TileStats {
    var frames = 0
    var plans = 0
    /// Planned regions drawn from another bucket, the thumbnail, or paper.
    var fallbackBucket = 0
    var fallbackThumbnail = 0
    var fallbackPaper = 0
    /// Prepared frames that showed at least one fallback region.
    var framesWithFallback = 0
    var memoryWarnings = 0
}

/// Hops tile completions to the main actor, coalesced into one hop per run-loop turn.
final class TileSignal: Sendable {
    private let pending = Atomic<Bool>(false)
    private let handler = Mutex<(@MainActor @Sendable () -> Void)?>(nil)

    func setHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler.withLock { $0 = handler }
    }

    func fire() {
        guard !pending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        DispatchQueue.main.async { [self] in
            pending.store(false, ordering: .releasing)
            let handler = handler.withLock { $0 }
            MainActor.assumeIsolated { handler?() }
        }
    }
}
