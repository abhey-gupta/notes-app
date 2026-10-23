import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing
import UIKit

@MainActor
final class Recorder: InkEngineDelegate {
    var commits: [(Stroke, PageID)] = []
    var eraser: [([Sample], PageID)] = []
    var lassos: [([CGPoint], PageID)] = []
    var begins = 0

    func engine(_: any InkEngine, didCommit stroke: Stroke, to page: PageID) {
        commits.append((stroke, page))
    }

    func engine(_: any InkEngine, didReceiveEraser samples: [Sample], to page: PageID) {
        eraser.append((samples, page))
    }

    func engine(_: any InkEngine, didReceiveLasso path: [CGPoint], to page: PageID) {
        lassos.append((path, page))
    }

    func engineDidBeginStroke(_: any InkEngine) {
        begins += 1
    }
}

/// Three stacked A4 pages in a 1024 × 1366 viewport, page 2 holding one stroke.
@MainActor
struct Harness {
    let engine = PencilKitInkEngine(palette: FixturePalette())
    let recorder = Recorder()
    let frames = RenderFixtures.stackedPages(3)
    var snapshots: [PageSnapshot]

    init() {
        snapshots = frames.map { PageSnapshot(page: Page(id: $0.id, template: .lined(spacing: 24)), size: RenderFixtures.pageSize) }
        let existing = RenderFixtures.line(9, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 50))
        snapshots[1] = snapshots[1].appending([existing])
        engine.delegate = recorder
        engine.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        engine.setPages(snapshots)
    }

    func scroll(toY y: CGFloat, zoom: CGFloat = 1) {
        engine.setViewport(Viewport(contentOffset: CGPoint(x: 0, y: y), zoomScale: zoom, size: engine.view.bounds.size, pages: frames))
    }

    /// What PencilKit does when the user finishes a stroke: appends it to the canvas drawing.
    func userDraws(_ stroke: Stroke) {
        var drawing = engine.canvas.drawing
        drawing.strokes.append(PencilKitConversion.pkStroke(from: stroke, color: .black))
        engine.canvas.drawing = drawing
        engine.canvasViewDrawingDidChange(engine.canvas)
    }
}

extension PageSnapshot {
    func appending(_ strokes: [Stroke]) -> PageSnapshot {
        // swiftlint:disable:next force_try
        try! applying(page.addEdit(strokes))
    }
}

@MainActor
struct EngineTests {
    @Test func activePageFollowsViewportAndCanvasCoversIt() {
        let h = Harness()
        h.scroll(toY: 900) // page 2 (content y 866...1708) nearest the center
        #expect(h.engine.activePage == h.frames[1].id)
        #expect(!h.engine.canvas.isHidden)
        #expect(h.engine.canvas.frame == CGRect(x: 0, y: 0, width: 595, height: 808))
        #expect(h.engine.canvas.contentOffset == CGPoint(x: 0, y: 34))
        #expect(h.engine.canvas.drawing.strokes.count == 1)
        #expect(h.engine.canvasIDs == [RenderFixtures.strokeID(9)])
    }

    @Test func canvasZoomsWithViewport() {
        let h = Harness()
        h.scroll(toY: 0, zoom: 2)
        #expect(h.engine.canvas.zoomScale == 2)
        #expect(h.engine.canvas.contentSize == CGSize(width: 1190, height: 1684))
        #expect(h.engine.canvas.frame == CGRect(x: 0, y: 0, width: 1024, height: 1366))
    }

    @Test func penDownOnAnotherPageMovesTheCanvas() {
        let h = Harness()
        h.scroll(toY: 900)
        #expect(h.engine.activePage == h.frames[1].id)
        // Page 3 starts at content y 1732 → view y 832.
        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 900))
        #expect(h.engine.activePage == h.frames[2].id)
        #expect(h.engine.canvas.frame.minY == 832)
        #expect(h.engine.canvas.drawing.strokes.isEmpty)
        // Touches between pages don't change it.
        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 820))
        #expect(h.engine.activePage == h.frames[2].id)
    }

    @Test func committedStrokeIsReportedAndEchoKeepsCanvas() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .pen(.brush), color: .semantic(.red), width: 5))
        let rebuilds = h.engine.rebuildCount

        h.userDraws(RenderFixtures.line(1, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 200, y: 120)))
        let (stroke, page) = try #require(h.recorder.commits.first)
        #expect(h.recorder.commits.count == 1)
        #expect(page == h.frames[1].id)
        #expect(stroke.tool == .brush)
        #expect(stroke.color == .semantic(.red))
        #expect(stroke.width == 5)
        #expect(stroke.samples.first?.x == 10)
        #expect(h.engine.pending[page]?.count == 1)

        // Document accepts it and echoes the edit back: no rebuild, nothing pending.
        let snapshot = try #require(h.engine.snapshots[page])
        h.engine.apply(snapshot.page.addEdit([stroke]), to: page)
        #expect(h.engine.pending[page]?.isEmpty ?? true)
        #expect(h.engine.rebuildCount == rebuilds)
        #expect(h.engine.canvasIDs == [RenderFixtures.strokeID(9), stroke.id])
        #expect(h.engine.snapshots[page]?.strokes.count == 2)
        #expect(h.recorder.commits.count == 1)
    }

    @Test func echoViaSetPagesAlsoKeepsCanvas() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.userDraws(RenderFixtures.line(1, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 200, y: 120)))
        let stroke = try #require(h.recorder.commits.first?.0)
        let rebuilds = h.engine.rebuildCount
        var pages = h.snapshots
        pages[1] = pages[1].appending([stroke])
        h.engine.setPages(pages)
        #expect(h.engine.rebuildCount == rebuilds)
        #expect(h.engine.pending[h.frames[1].id]?.isEmpty ?? true)
    }

    @Test func undoAndEraseEditsRebuildCanvas() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let snapshot = try #require(h.engine.snapshots[page])
        try h.engine.apply(snapshot.page.removeEdit([RenderFixtures.strokeID(9)]), to: page)
        #expect(h.engine.canvas.drawing.strokes.isEmpty)
        #expect(h.engine.canvasIDs.isEmpty)
        h.engine.apply(.add([PlacedStroke(index: 0, stroke: snapshot.strokes[0])]), to: page)
        #expect(h.engine.canvas.drawing.strokes.count == 1)
    }

    @Test func recolorRebuildsWithSameIDs() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let snapshot = try #require(h.engine.snapshots[page])
        let rebuilds = h.engine.rebuildCount
        try h.engine.apply(snapshot.page.recolorEdit([RenderFixtures.strokeID(9)], to: .semantic(.blue)), to: page)
        #expect(h.engine.rebuildCount == rebuilds + 1)
        let ink = try #require(h.engine.canvas.drawing.strokes.first?.ink.color)
        #expect(RGBA8(ink) == RGBA8(rgba: 0x2C4F_D6FF))
    }

    @Test func switchingPenTypeChangesPencilKitInk() throws {
        let h = Harness()
        for (kind, type) in [(PenKind.highlighter, PKInk.InkType.marker), (.fountain, .fountainPen), (.ballpoint, .pen)] {
            h.engine.setTool(ToolConfiguration(tool: .pen(kind)))
            let tool = try #require(h.engine.canvas.tool as? PKInkingTool)
            #expect(tool.inkType == type)
            #expect(h.engine.canvas.isUserInteractionEnabled)
            #expect(h.engine.input.isHidden)
        }
        #expect(h.engine.canvas.drawingPolicy == .pencilOnly)
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint), allowsFingerDrawing: true))
        #expect(h.engine.canvas.drawingPolicy == .anyInput)
    }

    @Test func eraserInputIsReportedIncrementallyInPageSpace() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .eraser, width: 20))
        #expect(!h.engine.input.isHidden)
        #expect(!h.engine.canvas.isUserInteractionEnabled)

        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        send(tracker.began(at(100, 100, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(120, 100, 0.01), coalesced: [at(110, 100, 0.005), at(120, 100, 0.01)]))
        send(tracker.ended(at(130, 100, 0.02)))

        #expect(h.recorder.begins == 1)
        #expect(h.recorder.eraser.map(\.0.count) == [1, 2, 1])
        #expect(h.recorder.eraser.allSatisfy { $0.1 == h.frames[1].id })
        // View y 100 at offset 900 → content 1000 → page 2 y 134.
        #expect(h.recorder.eraser.first?.0.first?.y == 134)
        #expect(h.recorder.commits.isEmpty)
    }

    @Test func lassoPathIsReportedOnLift() throws {
        let h = Harness()
        h.scroll(toY: 0)
        h.engine.setTool(ToolConfiguration(tool: .lasso))
        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        for events in [
            tracker.began(at(10, 10, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) },
            tracker.moved(at(50, 10, 0.01)),
            tracker.moved(at(50, 50, 0.02)),
            tracker.ended(at(10, 50, 0.03)),
        ] {
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        let (path, page) = try #require(h.recorder.lassos.first)
        #expect(page == h.frames[0].id)
        #expect(path == [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 50), CGPoint(x: 10, y: 50)])
        #expect(h.recorder.eraser.isEmpty)
    }

    @Test func canvasHasNoPinchOfItsOwn() {
        let h = Harness()
        for zoom in [1, 2, 0.75] as [CGFloat] {
            h.scroll(toY: 0, zoom: zoom)
            #expect(h.engine.canvas.zoomScale == zoom)
            let pinch = h.engine.canvas.pinchGestureRecognizer
            #expect(pinch == nil || pinch?.isEnabled == false)
        }
    }

    /// Strokes PencilKit captured come back exactly when the canvas is rebuilt from the document
    /// (page switch, undo, theme) — the bug behind "ink changes weight after scrolling" (#71).
    @Test func rebuiltCanvasRedrawsCapturedStrokesExactly() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let captured = try #require(LosslessRoundTripTests.capturedLikeStrokes().first)
        var drawing = h.engine.canvas.drawing
        drawing.strokes.append(captured)
        h.engine.canvas.drawing = drawing
        h.engine.canvasViewDrawingDidChange(h.engine.canvas)
        let stroke = try #require(h.recorder.commits.first?.0)
        let snapshot = try #require(h.engine.snapshots[page])
        h.engine.apply(snapshot.page.addEdit([stroke]), to: page)

        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 900)) // page 3
        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 400)) // back to page 2: rebuilt from the snapshot
        let rebuilt = try #require(h.engine.canvas.drawing.strokes.last)
        #expect(rebuilt.randomSeed == captured.randomSeed)
        #expect(rebuilt.ink.inkType == captured.ink.inkType)
        #expect(rebuilt.path.map(\.size) == captured.path.map(\.size))
        #expect(rebuilt.path.map(\.opacity) == captured.path.map(\.opacity))
        #expect(rebuilt.path.map(\.location) == captured.path.map(\.location))
    }

    @Test func pageKeepsItsRasterUntilTheCanvasHasDrawnIt() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        let page2 = try #require(h.engine.pageViews[h.frames[1].id])
        #expect(!page2.showsInk)

        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 900)) // page 3 becomes active
        let page3 = try #require(h.engine.pageViews[h.frames[2].id])
        #expect(page3.showsInk) // canvas hasn't drawn page 3 yet
        #expect(page2.showsInk)
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        #expect(!page3.showsInk)
        #expect(page2.showsInk)
    }

    @Test func pendingStrokesAreInTheInactiveRaster() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.userDraws(RenderFixtures.line(1, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 200, y: 120)))
        // Leave before the document echoes the stroke: the raster must still include it.
        h.engine.willReceiveTouch(at: CGPoint(x: 100, y: 900))
        let key = try #require(h.engine.pageViews[h.frames[1].id]?.requestedKey)
        #expect(key.strokeCount == 1)
        #expect(key.pendingCount == 1)
    }

    @Test func pagesLeavingTheViewportAreDropped() {
        let h = Harness()
        h.scroll(toY: 0)
        #expect(h.engine.pagesView.subviews.count == 3)
        h.engine.setViewport(Viewport(
            contentOffset: CGPoint(x: 0, y: 1800), zoomScale: 1, size: h.engine.view.bounds.size, pages: [h.frames[2]]
        ))
        #expect(h.engine.pagesView.subviews.count == 1)
        #expect(h.engine.activePage == h.frames[2].id)
    }
}

@MainActor
struct RenderTests {
    @Test func rendersPaperTemplateAndInk() async throws {
        let engine = PencilKitInkEngine(palette: FixturePalette())
        let page = RenderFixtures.allPens
        let image = try #require(await engine.render(page: page, size: page.size, scale: 1))
        #expect(image.width == 595)
        #expect(image.height == 842)
        let pixels = RGBAPixels(image)
        #expect(pixels[300, 30] == RGBA8(r: 255, g: 255, b: 255)) // paper above the first rule
        let ink = pixels[300, 160] // ballpoint line, primary ink
        #expect(ink.r < 120 && ink.g < 120 && ink.b < 120)
    }

    @Test func thumbnailScalesAndFollowsTheme() async throws {
        let engine = PencilKitInkEngine(palette: FixturePalette())
        engine.setTheme(.night)
        let page = RenderFixtures.blank
        let image = try #require(await engine.render(page: page, size: CGSize(width: 176, height: 228), scale: 2))
        #expect(image.width == 352)
        #expect(image.height == 456)
        #expect(RGBAPixels(image)[10, 10] == RGBA8(rgba: 0x1B1C_1FFF))
    }

    @Test func degenerateSizeRendersNothing() async {
        let engine = PencilKitInkEngine(palette: FixturePalette())
        #expect(await engine.render(page: RenderFixtures.blank, size: .zero, scale: 2) == nil)
    }
}

/// Redraws a `CGImage` into 8-bit sRGB RGBA for pixel checks.
struct RGBAPixels {
    let width: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    /// Pixel at `(x, y)`, origin top-left.
    subscript(x: Int, y: Int) -> RGBA8 {
        let i = (y * width + x) * 4
        return RGBA8(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
    }
}
