import CoreGraphics
import FixtureGen
import Foundation
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkModel
import Metal
import Testing

struct TimeoutError: Error, CustomStringConvertible {
    var description: String
}

extension MetalInkEngine {
    /// Builds land, then frames until every visible and prefetch tile is current.
    func settle(timeout: Duration = .seconds(20)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            await waitForBuilds()
            drawFrame()
            if buildTasks.isEmpty, tiles?.isIdle ?? true {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TimeoutError(description: "engine never settled: builds \(buildTasks.count), \(tiles?.diagnostics ?? "")")
    }
}

extension TiledContentRenderer {
    var diagnostics: String {
        let stale = cache.entries.filter(\.value.isStale).map(\.key)
        return "depth \(renderer.depth), staged \(staged.count), complete \(planWasComplete), needsPlan \(needsPlan), "
            + "frozen \(String(describing: frozenBucket)), stale \(stale), unsettled \(unsettled.count), deferred \(renderer.stats.deferred)"
    }
}

/// Renders committed content alone (no drawable): prepare + draw into an offscreen target, read back.
@MainActor
enum ContentCapture {
    static var gpu: GPUContext {
        get throws {
            try #require(GPUContext.shared)
        }
    }

    /// A frame target of `size` pt at 2 px/pt.
    static func target(_ size: CGSize = CGSize(width: 1024, height: 1366), scale: CGFloat = 2) -> FrameTarget {
        FrameTarget(
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bounds: size,
            pixelsPerPoint: scale
        )
    }

    /// A tile renderer for tests: no HUD, no zoom settling, a generous budget unless given.
    static func tiles(budget: Int = 512 << 20) throws -> TiledContentRenderer {
        var config = TiledContentRenderer.Configuration()
        config.budget = budget
        config.zoomSettleDelay = 0
        config.registersGauges = false
        return try #require(TiledContentRenderer(gpu: gpu, configuration: config))
    }

    /// One prepare without drawing (lets the planner run and queue renders).
    static func prepare(_ renderer: any CommittedContentRenderer, _ scene: ContentScene) throws {
        let commandBuffer = try #require(gpu.frameQueue.makeCommandBuffer())
        renderer.prepare(scene, commandBuffer: commandBuffer)
        commandBuffer.commit()
    }

    /// Prepares until the tiles for `scene` are all current.
    static func settle(_ tiles: TiledContentRenderer, _ scene: ContentScene, timeout: Duration = .seconds(20)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try prepare(tiles, scene)
            if tiles.isIdle {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TimeoutError(description: "tiles never settled: \(tiles.diagnostics)")
    }

    /// Prepares (once) and draws `renderer` for `scene` into an offscreen texture.
    static func capture(_ renderer: any CommittedContentRenderer, _ scene: ContentScene) async throws -> RGBAPixels {
        let gpu = try gpu
        let w = scene.pixelWidth
        let h = scene.pixelHeight
        let target = try #require(gpu.makeTarget(width: w, height: h, label: "test.capture"))
        let readback = try #require(gpu.device.makeBuffer(length: w * h * 4, options: .storageModeShared))
        let commandBuffer = try #require(gpu.frameQueue.makeCommandBuffer())
        renderer.prepare(scene, commandBuffer: commandBuffer)
        let encoder = try #require(SceneEncoder.beginPass(target, load: .clear, MTLClearColor(), commandBuffer, "test.capture"))
        renderer.draw(in: encoder)
        encoder.endEncoding()
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: w * 4,
            destinationBytesPerImage: w * h * 4
        )
        blit.endEncoding()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in done.resume() }
            commandBuffer.commit()
        }
        let data = Data(bytes: readback.contents(), count: w * h * 4)
        return try RGBAPixels(#require(OffscreenRenderer.makeImage(bgra: data, width: w, height: h)))
    }
}

/// Realistic notebook pages (FixtureGen: ~400 strokes, mixed pens and templates) stacked like
/// `PageLayout` (A4, 24 pt gap).
enum FixturePages {
    static let gap: CGFloat = 24

    static func make(_ count: Int, seed: UInt64 = 1) -> (snapshots: [PageSnapshot], frames: [VisiblePage]) {
        let generator = FixtureGenerator(FixtureSpec(pages: count, seed: seed))
        let size = Notebook.a4Portrait
        var snapshots: [PageSnapshot] = []
        var frames: [VisiblePage] = []
        for i in 0 ..< count {
            let page = generator.page(at: i)
            snapshots.append(PageSnapshot(page: page, size: size))
            frames.append(VisiblePage(id: page.id, frame: CGRect(x: 0, y: CGFloat(i) * (size.height + gap), width: size.width, height: size.height)))
        }
        return (snapshots, frames)
    }
}

extension Golden.Difference: CustomStringConvertible {
    public var description: String {
        String(format: "%.4f%% pixels differ > %d, mean Δ %.3f", differingFraction * 100, Golden.pixelThreshold, meanDelta)
    }
}

/// Writes perf numbers where a human can find them (simulator: relative only).
enum PerfReport {
    static let url = URL(fileURLWithPath: "/tmp/InkEngineMetalPerf/tiles.txt")

    static func append(_ line: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        FileHandle.standardError.write(Data(("[tiles] " + line + "\n").utf8))
    }
}
