import CoreGraphics
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkGeometry
import InkModel
import Metal
import Testing
import UIKit

/// Three stacked A4 pages in a 1024 × 1366 viewport; page 2 holds three strokes.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct Harness {
    let engine: MetalInkEngine
    let recorder = Recorder()
    let frames = RenderFixtures.stackedPages(3)
    var snapshots: [PageSnapshot]

    init() throws {
        engine = try #require(MetalInkEngine(palette: FixturePalette()))
        snapshots = frames.map { PageSnapshot(page: Page(id: $0.id, template: .lined(spacing: 24)), size: RenderFixtures.pageSize) }
        snapshots[1] = snapshots[1].appending([
            RenderFixtures.line(1, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 50)),
            RenderFixtures.wave(2, origin: CGPoint(x: 50, y: 300)),
            RenderFixtures.line(3, from: CGPoint(x: 50, y: 600), to: CGPoint(x: 500, y: 600), tool: .highlighter, width: 16),
        ])
        engine.delegate = recorder
        engine.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        engine.view.layoutIfNeeded()
        engine.setPages(snapshots)
        scroll(toY: 900)
    }

    func scroll(toY y: CGFloat, zoom: CGFloat = 1) {
        engine.setViewport(Viewport(contentOffset: CGPoint(x: 0, y: y), zoomScale: zoom, size: engine.view.bounds.size, pages: frames))
    }

    var page2: PageID {
        frames[1].id
    }

    /// Feeds a Pencil gesture along `points` (view space) through the shared input pipeline.
    func draw(_ points: [CGPoint], touch: UInt = 7) {
        let id = TouchID(touch)
        let records = points.enumerated().map { i, p in
            TouchRecord(id: id, location: p, timestamp: 100 + Double(i) / 240, force: 2)
        }
        let target = engine.inkInputView(engine.hostView.input, targetAt: points[0])
        var stroke = LiveStroke(touch: records[0], page: target?.page ?? page2, viewToPage: target?.viewToPage ?? .identity)
        stroke.append(coalesced: [records[0]], predicted: [])
        engine.inkInputView(engine.hostView.input, didProduce: .began(stroke))
        for i in 1 ..< records.count {
            let predicted = TouchRecord(
                id: id,
                location: CGPoint(x: points[i].x + 8, y: points[i].y),
                timestamp: records[i].timestamp + 0.01
            )
            stroke.append(coalesced: [records[i]], predicted: i < records.count - 1 ? [predicted] : [])
            engine.inkInputView(engine.hostView.input, didProduce: .updated(stroke))
        }
        stroke.finish()
        engine.inkInputView(engine.hostView.input, didProduce: .ended(stroke))
    }
}

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct BufferCacheTests {
    @Test func buildsEveryPageOnceAndTessellatesEachStrokeOnce() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        #expect(h.engine.pageBuffers.count == 3)
        #expect(h.engine.tessellationCount == 3)
        #expect(h.engine.meshCache.count == 3)
        let buffers = try #require(h.engine.pageBuffers[h.page2])
        #expect(buffers.strokeIDs.count == 3)
        #expect(buffers.highlightGroups.count == 1)
        #expect(!buffers.ink.isEmpty)

        // Same snapshots again: nothing rebuilt.
        let builds = h.engine.buildCount
        h.engine.setPages(h.snapshots)
        await h.engine.waitForBuilds()
        #expect(h.engine.buildCount == builds)
        #expect(h.engine.pageBuffers[h.page2] === buffers)
    }

    @Test func addOnlyTessellatesTheNewStroke() async throws {
        var h = try Harness()
        await h.engine.waitForBuilds()
        let stroke = RenderFixtures.line(20, from: CGPoint(x: 40, y: 700), to: CGPoint(x: 400, y: 720))
        let edit = h.snapshots[1].page.addEdit([stroke])
        h.snapshots[1] = try h.snapshots[1].applying(edit)
        h.engine.apply(edit, to: h.page2)
        await h.engine.waitForBuilds()
        #expect(h.engine.tessellationCount == 4)
        #expect(h.engine.pageBuffers[h.page2]?.strokeIDs.contains(stroke.id) == true)
    }

    @Test func recolorAndThemeRestyleWithoutTessellating() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        let id = RenderFixtures.strokeID(1)
        let before = try #require(h.engine.pageBuffers[h.page2])
        try h.engine.apply(h.snapshots[1].page.recolorEdit([id], to: .semantic(.red)), to: h.page2)
        await h.engine.waitForBuilds()
        let after = try #require(h.engine.pageBuffers[h.page2])
        #expect(after !== before)
        #expect(h.engine.tessellationCount == 3)
        #expect(style(after, 0).color == FixturePalette().ink(.semantic(.red), on: .white).simd)

        h.engine.setTheme(.night)
        await h.engine.waitForBuilds()
        #expect(h.engine.tessellationCount == 3)
        let night = try #require(h.engine.pageBuffers[h.page2])
        #expect(night.theme == .night)
        #expect(style(night, 0).color == FixturePalette().ink(.semantic(.red), on: .night).simd)
    }

    @Test func transformRetessellatesMovedStrokesOnly() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        let edit = try h.snapshots[1].page.transformEdit([RenderFixtures.strokeID(2)], by: CGAffineTransform(translationX: 10, y: 20))
        h.engine.apply(edit, to: h.page2)
        await h.engine.waitForBuilds()
        #expect(h.engine.tessellationCount == 4)
        let moved = try #require(h.engine.meshCache[RenderFixtures.strokeID(2)])
        #expect(moved.bounds.minY > 270)
    }

    @Test func removeKeepsGeometryForUndo() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        let remove = try h.snapshots[1].page.removeEdit([RenderFixtures.strokeID(1)])
        h.engine.apply(remove, to: h.page2)
        await h.engine.waitForBuilds()
        #expect(h.engine.pageBuffers[h.page2]?.strokeIDs.count == 2)
        h.engine.apply(remove.inverse(), to: h.page2)
        await h.engine.waitForBuilds()
        #expect(h.engine.pageBuffers[h.page2]?.strokeIDs.count == 3)
        #expect(h.engine.tessellationCount == 3)
    }

    @Test func invalidateRetessellatesIntersectingStrokes() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        h.engine.invalidate(CGRect(x: 0, y: 280, width: 595, height: 100), in: h.page2) // the wave only
        await h.engine.waitForBuilds()
        #expect(h.engine.tessellationCount == 4)
    }

    @Test func droppedPagesReleaseBuffersAndGeometry() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        h.engine.setPages([h.snapshots[0]])
        await h.engine.waitForBuilds()
        #expect(h.engine.pageBuffers.count == 1)
        #expect(h.engine.meshCache.isEmpty)
    }

    @Test func rapidEditsCoalesceAndLandOnTheLatestSnapshot() async throws {
        let h = try Harness()
        var snapshot = h.snapshots[1]
        for i in 0 ..< 10 {
            let stroke = RenderFixtures.line(UInt8(30 + i), from: CGPoint(x: 40, y: 400 + i * 10), to: CGPoint(x: 400, y: 400 + i * 10))
            let edit = snapshot.page.addEdit([stroke])
            snapshot = try snapshot.applying(edit)
            h.engine.apply(edit, to: h.page2)
        }
        await h.engine.waitForBuilds()
        #expect(h.engine.pageBuffers[h.page2]?.snapshot == snapshot)
        #expect(h.engine.buildCount < 3 + 10)
        #expect(h.engine.tessellationCount == 13)
    }

    @Test func highlighterGroupsHaveDisjointBounds() {
        let a = RenderFixtures.line(1, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), tool: .highlighter, width: 10)
        let b = RenderFixtures.line(2, from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20), tool: .highlighter, width: 10)
        let c = RenderFixtures.line(3, from: CGPoint(x: 0, y: 100), to: CGPoint(x: 100, y: 100), tool: .highlighter, width: 10)
        let ink = RenderFixtures.line(4, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        let strokes = [a, ink, b, c]
        let geometry = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, StrokeGeometry($0, fringe: 1)) })
        #expect(PageBuilder.highlightGroups(strokes, geometry) == [[0, 3], [2]])
    }

    private func style(_ buffers: PageBuffers, _ z: Int) -> StrokeStyle {
        guard let styles = buffers.styles else { return StrokeStyle(color: .zero) }
        return styles.contents().assumingMemoryBound(to: StrokeStyle.self)[z]
    }
}

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct InputTests {
    @Test func penStrokeCommitsOnceAndStaysPendingUntilEchoed() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        h.engine.setTool(ToolConfiguration(tool: .pen(.fountain), color: .semantic(.blue), width: 3))
        // Page 2 spans view y −34...808 at offset 900.
        h.draw((0 ..< 20).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 200 + CGFloat($0)) })
        #expect(h.recorder.begins == 1)
        #expect(h.recorder.commits.count == 1)
        let (stroke, page) = try #require(h.recorder.commits.first)
        #expect(page == h.page2)
        #expect(stroke.tool == .fountain && stroke.color == .semantic(.blue) && stroke.width == 3)
        #expect(stroke.samples.count == 20)
        // View (100, 200) → page (100, 234).
        #expect(abs(stroke.samples[0].y - 234) < 0.01)
        #expect(h.engine.pending[h.page2]?.count == 1)
        #expect(h.engine.live == nil)

        // The document echoes it: the build re-uses the geometry seeded at commit and drops the pending copy.
        h.engine.apply(h.snapshots[1].page.addEdit([stroke]), to: h.page2)
        await h.engine.waitForBuilds()
        #expect(h.engine.pending[h.page2]?.isEmpty != false)
        #expect(h.engine.tessellationCount == 3)
    }

    @Test func eraserReportsIncrementalBatchesAndNeverCommits() throws {
        let h = try Harness()
        h.engine.setTool(ToolConfiguration(tool: .eraser, width: 20))
        h.draw((0 ..< 5).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 200) })
        #expect(h.recorder.commits.isEmpty)
        #expect(h.recorder.eraser.map(\.0.count).reduce(0, +) == 5)
        #expect(h.recorder.eraser.count == 5)
    }

    @Test func lassoReportsThePathOnPenUp() throws {
        let h = try Harness()
        h.engine.setTool(ToolConfiguration(tool: .lasso))
        h.draw((0 ..< 12).map { CGPoint(x: 100 + 40 * cos(CGFloat($0) / 2), y: 300 + 40 * sin(CGFloat($0) / 2)) })
        #expect(h.recorder.commits.isEmpty)
        #expect(h.recorder.lassos.count == 1)
        #expect(h.recorder.lassos.first?.0.count == 12)
    }

    @Test func offPageTouchesAreIgnored() throws {
        let h = try Harness()
        h.scroll(toY: 0, zoom: 0.5) // page 1 spans x 0...297.5
        #expect(h.engine.inkInputView(h.engine.hostView.input, targetAt: CGPoint(x: 600, y: 100)) == nil)
        #expect(h.engine.inkInputView(h.engine.hostView.input, targetAt: CGPoint(x: 100, y: 100))?.page == h.frames[0].id)
    }
}

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct FrameTests {
    @Test func liveFramesReuseTheCompositeUntilContentChanges() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        let frames = h.engine.frameCount
        h.engine.drawFrame()
        try #require(h.engine.frameCount == frames + 1, "no drawable (layer not presentable here)")
        let renders = h.engine.content.renderCount
        h.engine.drawFrame()
        #expect(h.engine.content.renderCount == renders)

        // A whole pen stroke: every touch event draws a frame, none re-renders committed content.
        h.draw((0 ..< 30).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 300) })
        #expect(h.engine.frameCount >= frames + 31)
        #expect(h.engine.content.renderCount == renders)

        // A live highlighter too (coverage pass + resolve, still no composite render).
        h.engine.setTool(ToolConfiguration(tool: .pen(.highlighter), color: .semantic(.accent), width: 14))
        h.draw((0 ..< 10).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 400) })
        #expect(h.engine.content.renderCount == renders)

        // Viewport moves: re-rendered once on the next frame.
        h.scroll(toY: 950)
        h.engine.drawFrame()
        h.engine.drawFrame()
        #expect(h.engine.content.renderCount == renders + 1)
    }

    @Test func displayLinkRunsOnlyWhileActive() async throws {
        let h = try Harness()
        await h.engine.waitForBuilds()
        let driver = h.engine.driver
        driver.scrollLinger = 0.05
        h.scroll(toY: 920)
        #expect(driver.isRunning)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!driver.isRunning)
        #expect(!driver.isActive(.scroll))
    }
}

@Suite(.timeLimit(.minutes(2)))
struct LayoutTests {
    @Test func shaderStructLayoutsMatchMetal() {
        #expect(MemoryLayout<StrokeVertex>.stride == 24)
        #expect(MemoryLayout<PageTransform>.stride == 32)
        #expect(MemoryLayout<StrokeStyle>.stride == 80)
        #expect(MemoryLayout<StrokeStyle>.offset(of: \.start) == 32)
        #expect(MemoryLayout<BackgroundUniforms>.stride == 64)
        #expect(MemoryLayout<BackgroundUniforms>.offset(of: \.pageSize) == 32)
        #expect(MemoryLayout<StrokeStyle>.offset(of: \.softness) == 16)
    }

    @Test func pageTransformMapsPageToClipSpace() {
        let t = PageTransform(
            pageToTarget: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -100, ty: 50),
            targetSize: CGSize(width: 400, height: 200),
            pixelsPerPoint: 2
        )
        func clip(_ p: SIMD2<Float>) -> SIMD2<Float> {
            p * t.scale + t.offset
        }
        #expect(clip(SIMD2(50, -25)) == SIMD2(-1, 1)) // view (0, 0)
        #expect(clip(SIMD2(250, 75)) == SIMD2(1, -1)) // view (400, 200)
        #expect(t.ppp == 4)
    }
}
