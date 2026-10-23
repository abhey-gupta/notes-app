import CoreGraphics
import Foundation
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkModel
import Metal
import Testing

/// Scroll the 300-page fixture like the canvas host would (ARCHITECTURE.md §5, §11). Simulator numbers
/// are relative only; the 120 Hz / hitch budgets are verified on device.
@MainActor
@Suite(.serialized)
struct ScrollSimulationTests {
    static let viewSize = CGSize(width: 1024, height: 1366)
    static let pitch = Notebook.a4Portrait.height + FixturePages.gap

    /// Feeds `engine` what the host sends at `y`: visible ± 3 snapshots (only when that window
    /// changes), visible ± 1 frames.
    @MainActor
    final class Host {
        let engine: MetalInkEngine
        let fixture: (snapshots: [PageSnapshot], frames: [VisiblePage])
        private var window: Range<Int>?

        init(_ engine: MetalInkEngine, pages: Int) {
            self.engine = engine
            fixture = FixturePages.make(pages)
        }

        var total: CGFloat {
            CGFloat(fixture.frames.count) * ScrollSimulationTests.pitch - FixturePages.gap - ScrollSimulationTests.viewSize.height
        }

        func scroll(to y: CGFloat) {
            let count = fixture.frames.count
            let pitch = ScrollSimulationTests.pitch
            let first = min(max(Int(y / pitch), 0), count - 1)
            let last = min(Int((y + ScrollSimulationTests.viewSize.height) / pitch), count - 1)
            let window = max(first - 3, 0) ..< min(last + 4, count)
            if window != self.window {
                self.window = window
                engine.setPages(Array(fixture.snapshots[window]))
            }
            let frames = Array(fixture.frames[max(first - 1, 0) ... min(last + 1, count - 1)])
            engine.setViewport(Viewport(
                contentOffset: CGPoint(x: 0, y: y),
                zoomScale: 1,
                size: ScrollSimulationTests.viewSize,
                pages: frames
            ))
        }
    }

    /// A fast fling: 48 pt per 120 Hz frame (5760 pt/s), top to bottom, paced like the display.
    @MainActor
    struct Fling {
        var frameTimes: [Double] = []
        var elapsed: Double = 0
        var peakPool = 0
        var peakCache = 0
        var maxBuffers = 0
        var peakFootprint = 0

        static func run(_ host: Host, engine: MetalInkEngine, tiles: TiledContentRenderer) async throws -> Fling {
            var run = Fling()
            let clock = ContinuousClock()
            let interval = Duration.nanoseconds(8_333_333)
            var next = clock.now
            var y: CGFloat = 0
            let start = clock.now
            while y < host.total {
                y = min(y + 48, host.total)
                host.scroll(to: y)
                let t0 = clock.now
                engine.drawFrame()
                run.frameTimes.append((clock.now - t0) / .seconds(1))
                run.peakPool = max(run.peakPool, tiles.pool.allocatedBytes)
                run.peakCache = max(run.peakCache, tiles.cache.bytes)
                run.maxBuffers = max(run.maxBuffers, engine.pageBuffers.count)
                if run.frameTimes.count % 30 == 0 {
                    run.peakFootprint = max(run.peakFootprint, Self.footprint())
                }
                next += interval
                try await clock.sleep(until: next)
            }
            run.elapsed = (clock.now - start) / .seconds(1)
            return run
        }

        /// The process's physical footprint (bytes): what jetsam counts.
        static func footprint() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(Int(Double(sorted.count - 1) * p), sorted.count - 1)]
    }

    @Test(.timeLimit(.minutes(5)))
    func scrolling300PagesNeverWaitsOnTilesAndStaysInBudget() async throws {
        let engine = try #require(MetalInkEngine(palette: FixturePalette(), contentMode: .tiles))
        let tiles = try #require(engine.tiles)
        engine.view.frame = CGRect(origin: .zero, size: Self.viewSize)
        engine.view.layoutIfNeeded()
        let host = Host(engine, pages: 300)
        // Open at page 1 and let the first screen settle (on device the thumbnail covers this).
        host.scroll(to: 0)
        try await engine.settle()
        tiles.prepareTimes = []
        let startTiles = tiles.renderer.stats
        let startStats = tiles.stats

        let run = try await Fling.run(host, engine: engine, tiles: tiles)
        let frameTimes = run.frameTimes

        let prepare = tiles.prepareTimes ?? []
        let rendered = tiles.renderer.stats.tiles - startTiles.tiles
        let encode = (tiles.renderer.stats.encodeSeconds - startTiles.encodeSeconds) / Double(max(rendered, 1))
        let gpu = (tiles.renderer.stats.gpuSeconds - startTiles.gpuSeconds) / Double(max(rendered, 1))
        let fallbackFrames = tiles.stats.framesWithFallback - startStats.framesWithFallback
        let budget = tiles.configuration.budget
        PerfReport.append(String(
            format: "scroll 300p: %d frames in %.1f s (%.0f fps paced); frame CPU p50 %.2f p99 %.2f max %.2f ms; "
                + "prepare CPU p50 %.3f p99 %.3f max %.3f ms; %d tiles rendered, %.2f ms encode + %.2f ms GPU per tile; "
                + "fallback frames %d (bucket %d, paper %d regions); peak pool %d MiB, cache %d MiB (end %d / %d), budget %d MiB; "
                + "max page buffers %d; peak footprint %d MiB",
            frameTimes.count, run.elapsed, Double(frameTimes.count) / run.elapsed,
            Self.percentile(frameTimes, 0.5) * 1000, Self.percentile(frameTimes, 0.99) * 1000, (frameTimes.max() ?? 0) * 1000,
            Self.percentile(prepare, 0.5) * 1000, Self.percentile(prepare, 0.99) * 1000, (prepare.max() ?? 0) * 1000,
            rendered, encode * 1000, gpu * 1000,
            fallbackFrames, tiles.stats.fallbackBucket - startStats.fallbackBucket, tiles.stats.fallbackPaper - startStats.fallbackPaper,
            run.peakPool >> 20, run.peakCache >> 20, tiles.pool.allocatedBytes >> 20, tiles.cache.bytes >> 20, budget >> 20, run.maxBuffers,
            run.peakFootprint >> 20
        ))

        // No frame waits on a tile: renders only ever run on the tile queue, and planning stays far
        // below a frame even at its worst (a wait would cost a whole tile render or more).
        #expect(tiles.renderer.stats.onMainThread == 0)
        #expect(Self.percentile(prepare, 0.99) < 0.002)
        #expect(rendered > 100)
        // Memory: tiles within budget, GPU buffers for visible ± 3 only (a 1366 pt view spans ≤ 3 pages).
        #expect(run.peakPool <= budget)
        #expect(run.peakCache <= budget)
        #expect(run.maxBuffers <= 3 + 2 * MetalInkEngine.bufferRadius)
        // Whole test process (fixture, engine, tiles; on the simulator GPU memory is host memory).
        #expect(run.peakFootprint > 0 && run.peakFootprint < 400 << 20)
    }

    /// Committed-content cost per frame while scrolling, tiles vs the viewport composite (warm tile
    /// cache; each frame waits for the GPU so the rate reflects its cost).
    @Test func compositeThroughputTilesVersusViewportComposite() async throws {
        let h = try await ContentHarness(pages: 4)
        let tiles = try ContentCapture.tiles()
        let composite = try ViewportCompositeRenderer(gpu: ContentCapture.gpu)
        let scenes = stride(from: CGFloat(0), to: 2 * Self.pitch, by: 24).map { h.scene(y: $0) }
        for scene in scenes {
            try await ContentCapture.settle(tiles, scene)
        }
        func framesPerSecond(_ renderer: any CommittedContentRenderer) throws -> Double {
            let gpu = try ContentCapture.gpu
            let target = try #require(gpu.makeTarget(width: scenes[0].pixelWidth, height: scenes[0].pixelHeight, label: "test.frame"))
            let clock = ContinuousClock()
            let start = clock.now
            for scene in scenes {
                let commandBuffer = try #require(gpu.frameQueue.makeCommandBuffer())
                renderer.setNeedsDisplay()
                renderer.prepare(scene, commandBuffer: commandBuffer)
                let encoder = try #require(SceneEncoder.beginPass(target, load: .clear, MTLClearColor(), commandBuffer, "test.frame"))
                renderer.draw(in: encoder)
                encoder.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }
            return Double(scenes.count) / ((clock.now - start) / .seconds(1))
        }
        let tileRate = try framesPerSecond(tiles)
        let compositeRate = try framesPerSecond(composite)
        PerfReport.append(String(
            format: "composite fps (sim, relative): tiles %.0f, viewport composite %.0f (×%.1f)",
            tileRate,
            compositeRate,
            tileRate / compositeRate
        ))
        #expect(tiles.draws.fallbacks == 0)
        #expect(tileRate > compositeRate)
    }
}
