import CoreGraphics
import Dispatch
import Foundation
import Metal
import Perf

/// Renders tiles off main (ARCHITECTURE.md §5.4): a serial dispatch queue with its own
/// `MTLCommandQueue`, at most ``maxBatchesInFlight`` command buffers of ``batchSize`` tiles on the GPU.
///
/// The main actor replaces the whole queue with ``submit(_:)`` whenever its plan changes (nearest the
/// viewport center first), which also cancels queued tiles that left residency. Results collect in an
/// inbox (``takeResults()``) and `notify` fires so the next frame picks them up; nothing ever waits on
/// a render.
///
/// A tile = page background (procedural template) + highlighter pass + ink pass, drawing only the
/// strokes whose strips overlap the tile (``PageBuffers/selection(in:)``), via ``SceneEncoder``.
///
/// `@unchecked Sendable`: mutable state lives behind `lock`; the coverage scratch texture is only used
/// by command buffers encoded on the serial dispatch queue.
final class TileRenderer: @unchecked Sendable {
    static let batchSize = 4
    static let maxBatchesInFlight = 2

    struct Job: Sendable {
        var key: TileKey
        /// Invalidation generation the job was planned at (``TiledContentRenderer``).
        var generation: Int
        var buffers: PageBuffers
        var background: BackgroundUniforms
        var pageSize: CGSize
        var grid: TileGrid
        var blend: HighlightBlend
    }

    /// `@unchecked Sendable`: the texture changes hands once, after the GPU finished writing it.
    struct Result: @unchecked Sendable {
        var key: TileKey
        var generation: Int
        /// `nil`: not rendered (pool at capacity or GPU error); the planner asks again.
        var texture: (any MTLTexture)?
    }

    /// Cumulative render statistics.
    struct Stats: Sendable {
        var tiles = 0
        var batches = 0
        /// CPU time encoding tiles (s).
        var encodeSeconds: Double = 0
        /// GPU time of tile command buffers (s; 0 where the GPU doesn't report it).
        var gpuSeconds: Double = 0
        /// Renders that ran on the main thread (must stay 0).
        var onMainThread = 0
        var deferred = 0
    }

    private struct State {
        var queue: [Job] = []
        var started: Set<TileKey> = []
        var draining = false
        var results: [Result] = []
        var stats = Stats()
    }

    let pool: TexturePool
    private let gpu: GPUContext
    private let commandQueue: any MTLCommandQueue
    private let dispatch = DispatchQueue(label: "com.abhey.notespace.ink.tiles", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: TileRenderer.maxBatchesInFlight)
    private let lock = NSLock()
    private var state = State()
    private let notify: @Sendable () -> Void
    /// Highlighter coverage scratch, one tile in size (only touched on the render queue's command
    /// buffers, which the GPU runs in order).
    private let coverage: (any MTLTexture)?

    init?(gpu: GPUContext, pool: TexturePool, notify: @escaping @Sendable () -> Void) {
        guard let queue = gpu.device.makeCommandQueue() else { return nil }
        queue.label = "ink.tiles"
        self.gpu = gpu
        self.pool = pool
        self.notify = notify
        commandQueue = queue
        coverage = gpu.makeTarget(width: TileGrid.tilePixels, height: TileGrid.tilePixels, label: "ink.tiles.coverage")
    }

    /// Replaces the queue with `jobs` (in priority order). Jobs for tiles already on the GPU are dropped.
    func submit(_ jobs: [Job]) {
        let start = withLock { s in
            s.queue = jobs.filter { !s.started.contains($0.key) }
            guard !s.draining, !s.queue.isEmpty else { return false }
            s.draining = true
            return true
        }
        if start {
            dispatch.async { [self] in drain() }
        }
    }

    /// Tiles queued or rendering.
    var depth: (queued: Int, started: Int) {
        withLock { ($0.queue.count, $0.started.count) }
    }

    /// Keys on the GPU now.
    var startedKeys: Set<TileKey> {
        withLock { $0.started }
    }

    var stats: Stats {
        withLock { $0.stats }
    }

    /// Finished renders since the last call.
    func takeResults() -> [Result] {
        withLock { s in
            defer { s.results.removeAll(keepingCapacity: true) }
            return s.results
        }
    }

    // MARK: Render queue

    private func drain() {
        while true {
            slots.wait()
            let batch: [Job] = withLock { s in
                guard !s.queue.isEmpty else {
                    s.draining = false
                    return []
                }
                let n = min(Self.batchSize, s.queue.count)
                let batch = Array(s.queue.prefix(n))
                s.queue.removeFirst(n)
                s.started.formUnion(batch.map(\.key))
                return batch
            }
            guard !batch.isEmpty else {
                slots.signal()
                return
            }
            render(batch)
        }
    }

    private func render(_ batch: [Job]) {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            finish(batch.map { Result(key: $0.key, generation: $0.generation, texture: nil) }, encode: 0, gpu: 0)
            return
        }
        commandBuffer.label = "ink.tiles"
        var renders: [Rendered] = []
        var skipped: [Result] = []
        for job in batch {
            guard let texture = pool.allocate() else {
                skipped.append(Result(key: job.key, generation: job.generation, texture: nil))
                continue
            }
            let signpost = Signpost.tileRender.begin()
            encode(job, into: texture, commandBuffer)
            renders.append(Rendered(job: job, texture: texture, signpost: signpost))
        }
        let rendered = renders
        let deferred = skipped
        let encode = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let onMain = Thread.isMainThread
        commandBuffer.addCompletedHandler { [self] buffer in
            let ok = buffer.status == .completed
            if !ok {
                pool.recycle(rendered.map(\.texture))
            }
            for entry in rendered {
                entry.signpost.end()
            }
            let gpuTime = max(buffer.gpuEndTime - buffer.gpuStartTime, 0)
            let results = rendered.map { Result(key: $0.job.key, generation: $0.job.generation, texture: ok ? $0.texture : nil) }
            finish(results + deferred, encode: encode, gpu: gpuTime, rendered: ok ? rendered.count : 0, onMain: onMain)
        }
        commandBuffer.commit()
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// A tile encoded into a command buffer. `@unchecked Sendable`: only the completion handler
    /// touches it after encoding.
    private struct Rendered: @unchecked Sendable {
        var job: Job
        var texture: any MTLTexture
        var signpost: SignpostInterval
    }

    private func finish(_ results: [Result], encode: Double, gpu: Double, rendered: Int = 0, onMain: Bool = false) {
        withLock { s in
            s.results.append(contentsOf: results)
            for result in results {
                s.started.remove(result.key)
            }
            s.stats.tiles += rendered
            s.stats.batches += 1
            s.stats.encodeSeconds += encode
            s.stats.gpuSeconds += gpu
            s.stats.onMainThread += onMain ? 1 : 0
            s.stats.deferred += results.count(where: { $0.texture == nil })
        }
        slots.signal()
        notify()
    }

    /// Encodes `job` into `texture`: the tile's square of the page at the bucket's scale.
    private func encode(_ job: Job, into texture: any MTLTexture, _ commandBuffer: any MTLCommandBuffer) {
        let grid = job.grid
        let tile = grid.rect(of: job.key)
        let s = job.key.bucket.scale
        let side = CGFloat(TileGrid.tilePixels) / grid.pixelsPerPoint
        let pageToTile = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -tile.minX * s, ty: -tile.minY * s)
        let pageRect = CGRect(origin: .zero, size: job.pageSize).applying(pageToTile)
        let n = TileGrid.tilePixels
        guard let scissor = SceneEncoder.scissor(pageRect, pixelsPerPoint: grid.pixelsPerPoint, targetWidth: n, targetHeight: n) else {
            // Off the page (never planned): just clear.
            SceneEncoder.beginPass(texture, load: .clear, MTLClearColor(), commandBuffer, "tile")?.endEncoding()
            return
        }
        // One tile pixel of slack: strip bounds already include the AA fringe.
        let pixel = 1 / (s * grid.pixelsPerPoint)
        let page = ScenePage(
            transform: PageTransform(pageToTarget: pageToTile, targetSize: CGSize(width: side, height: side), pixelsPerPoint: grid.pixelsPerPoint),
            background: job.background,
            buffers: job.buffers,
            scissor: scissor,
            selection: job.buffers.selection(in: tile.insetBy(dx: -pixel, dy: -pixel))
        )
        let coverage = coverage
        SceneEncoder.encode(
            [page],
            into: SceneTarget(texture: texture, coverage: { coverage }),
            blend: job.blend,
            pipelines: gpu.pipelines,
            commandBuffer: commandBuffer
        )
    }
}
