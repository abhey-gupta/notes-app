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

/// Three stacked A4 pages (content y 0, 866, 1732) shown through a 1024 × 1366 viewport, page 2 holding
/// one stroke. The engine view is content-sized, as in the host.
@MainActor
struct Harness {
    let engine = PencilKitInkEngine(palette: FixturePalette())
    let recorder = Recorder()
    let frames = RenderFixtures.stackedPages(3)
    let viewSize = CGSize(width: 1024, height: 1366)
    var snapshots: [PageSnapshot]

    init() {
        snapshots = frames.map { PageSnapshot(page: Page(id: $0.id, template: .lined(spacing: 24)), size: RenderFixtures.pageSize) }
        let existing = RenderFixtures.line(9, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 50))
        snapshots[1] = snapshots[1].appending([existing])
        engine.delegate = recorder
        engine.view.frame = CGRect(x: 0, y: 0, width: 595, height: 2574)
        engine.setPages(snapshots)
    }

    func scroll(toY y: CGFloat, zoom: CGFloat = 1) {
        engine.setViewport(Viewport(contentOffset: CGPoint(x: 0, y: y), zoomScale: zoom, size: viewSize, pages: frames))
    }

    /// The canvas drawing page `index`.
    func canvas(_ index: Int) -> PageCanvas? {
        engine.canvas(for: frames[index].id)
    }

    /// What PencilKit does when the user finishes a stroke: appends it to the page's canvas drawing.
    func userDraws(_ stroke: Stroke, on index: Int = 1) {
        guard let canvas = canvas(index) else { return }
        var drawing = canvas.view.drawing
        drawing.strokes.append(PencilKitConversion.pkStroke(from: stroke, color: .black))
        canvas.view.drawing = drawing
        engine.canvasViewDrawingDidChange(canvas.view)
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
    @Test func visiblePagesGetCanvasesOverTheirVisiblePart() throws {
        let h = Harness()
        h.scroll(toY: 900) // shows content y 900...2266: page 2 (866...1708) and page 3 (1732...)
        #expect(h.canvas(0) == nil, "page 1 is off screen")
        let page2 = try #require(h.canvas(1))
        #expect(!page2.view.isHidden)
        #expect(page2.view.frame == CGRect(x: 0, y: 900, width: 595, height: 808))
        #expect(page2.view.contentOffset == CGPoint(x: 0, y: 34))
        #expect(page2.view.drawing.strokes.count == 1)
        #expect(page2.ids == [RenderFixtures.strokeID(9)])
        let page3 = try #require(h.canvas(2))
        #expect(page3.view.frame == CGRect(x: 0, y: 1732, width: 595, height: 534))
        #expect(page3.view.drawing.strokes.isEmpty)
        #expect(page2 !== page3)
    }

    @Test func canvasRendersAtTheZoomAndIsScaledBackIntoContentSpace() throws {
        let h = Harness()
        h.scroll(toY: 0, zoom: 2)
        let canvas = try #require(h.canvas(0))
        #expect(canvas.view.zoomScale == 2)
        #expect(canvas.view.contentSize == CGSize(width: 1190, height: 1684))
        #expect(canvas.view.transform.a == 0.5)
        #expect(canvas.view.frame == CGRect(x: 0, y: 0, width: 512, height: 683), "the visible half of the page")
        #expect(canvas.view.bounds == CGRect(x: 0, y: 0, width: 1024, height: 1366))
    }

    @Test func scrollingMovesCanvasesWithoutRebuilding() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let canvas = try #require(h.canvas(1))
        let rebuilds = h.engine.rebuildCount
        h.scroll(toY: 1000)
        #expect(h.canvas(1) === canvas)
        #expect(canvas.view.frame == CGRect(x: 0, y: 1000, width: 595, height: 708))
        #expect(canvas.view.contentOffset == CGPoint(x: 0, y: 134))
        #expect(h.engine.rebuildCount == rebuilds)
    }

    @Test func committedStrokeIsReportedForItsPageAndEchoKeepsCanvas() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .pen(.brush), color: .semantic(.red), width: 5))
        let rebuilds = h.engine.rebuildCount

        h.userDraws(RenderFixtures.line(1, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 200, y: 120)), on: 2)
        let (stroke, page) = try #require(h.recorder.commits.first)
        #expect(h.recorder.commits.count == 1)
        #expect(page == h.frames[2].id, "the page whose canvas drew it")
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
        #expect(h.canvas(2)?.ids == [stroke.id])
        #expect(h.engine.snapshots[page]?.strokes.count == 1)
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
        #expect(h.canvas(1)?.view.drawing.strokes.isEmpty == true)
        #expect(h.canvas(1)?.ids.isEmpty == true)
        h.engine.apply(.add([PlacedStroke(index: 0, stroke: snapshot.strokes[0])]), to: page)
        #expect(h.canvas(1)?.view.drawing.strokes.count == 1)
    }

    @Test func recolorRebuildsWithSameIDs() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let snapshot = try #require(h.engine.snapshots[page])
        let rebuilds = h.engine.rebuildCount
        try h.engine.apply(snapshot.page.recolorEdit([RenderFixtures.strokeID(9)], to: .semantic(.blue)), to: page)
        #expect(h.engine.rebuildCount == rebuilds + 1)
        let ink = try #require(h.canvas(1)?.view.drawing.strokes.first?.ink.color)
        #expect(RGBA8(ink) == RGBA8(rgba: 0x2C4F_D6FF))
    }

    @Test func switchingPenTypeChangesPencilKitInkOnEveryCanvas() throws {
        let h = Harness()
        h.scroll(toY: 900)
        #expect(h.engine.canvases.count == 2)
        for (kind, type) in [(PenKind.highlighter, PKInk.InkType.marker), (.fountain, .fountainPen), (.ballpoint, .pen)] {
            h.engine.setTool(ToolConfiguration(tool: .pen(kind)))
            for canvas in h.engine.canvases {
                let tool = try #require(canvas.view.tool as? PKInkingTool)
                #expect(tool.inkType == type)
                #expect(canvas.view.isUserInteractionEnabled)
            }
            #expect(h.engine.input.isHidden)
        }
        #expect(h.engine.canvases.allSatisfy { $0.view.drawingPolicy == .pencilOnly })
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint), allowsFingerDrawing: true))
        #expect(h.engine.canvases.allSatisfy { $0.view.drawingPolicy == .anyInput })
    }

    @Test func eraserInputIsReportedIncrementallyInPageSpace() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .eraser, width: 20))
        #expect(!h.engine.input.isHidden)
        #expect(h.engine.canvases.allSatisfy { !$0.view.isUserInteractionEnabled })

        var tracker = InkInputTracker()
        let at = { (x: CGFloat, y: CGFloat, t: Double) in TouchRecord(id: TouchID(1), location: CGPoint(x: x, y: y), timestamp: t) }
        let send = { (events: [InkInputTracker.Event]) in
            for event in events {
                h.engine.inkInputView(h.engine.input, didProduce: event)
            }
        }
        // The input view is content-sized: content (100, 1000) is page 2, page point (100, 134).
        send(tracker.began(at(100, 1000, 0)) { h.engine.inkInputView(h.engine.input, targetAt: $0) })
        send(tracker.moved(at(120, 1000, 0.01), coalesced: [at(110, 1000, 0.005), at(120, 1000, 0.01)]))
        send(tracker.ended(at(130, 1000, 0.02)))

        #expect(h.recorder.begins == 1)
        #expect(h.recorder.eraser.map(\.0.count) == [1, 2, 1])
        #expect(h.recorder.eraser.allSatisfy { $0.1 == h.frames[1].id })
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

    @Test func canvasesHaveNoPinchOfTheirOwn() {
        let h = Harness()
        for zoom in [1, 2, 0.75] as [CGFloat] {
            h.scroll(toY: 0, zoom: zoom)
            for canvas in h.engine.canvases where canvas.page != nil {
                #expect(canvas.view.zoomScale == zoom)
                let pinch = canvas.view.pinchGestureRecognizer
                #expect(pinch == nil || pinch?.isEnabled == false)
            }
        }
    }

    /// Strokes PencilKit captured come back exactly when the canvas is rebuilt from the document
    /// (page left and returned, undo, theme) — the bug behind "ink changes weight after scrolling" (#71).
    @Test func rebuiltCanvasRedrawsCapturedStrokesExactly() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let captured = try #require(LosslessRoundTripTests.capturedLikeStrokes().first)
        let canvas = try #require(h.canvas(1))
        var drawing = canvas.view.drawing
        drawing.strokes.append(captured)
        canvas.view.drawing = drawing
        h.engine.canvasViewDrawingDidChange(canvas.view)
        let stroke = try #require(h.recorder.commits.first?.0)
        let snapshot = try #require(h.engine.snapshots[page])
        h.engine.apply(snapshot.page.addEdit([stroke]), to: page)

        h.engine.setViewport(Viewport(contentOffset: CGPoint(x: 0, y: 1800), zoomScale: 1, size: h.viewSize, pages: [h.frames[2]]))
        #expect(h.canvas(1) == nil, "page 2 left the viewport: its canvas is released")
        h.scroll(toY: 900) // back: rebuilt from the snapshot
        let rebuilt = try #require(h.canvas(1)?.view.drawing.strokes.last)
        #expect(rebuilt.randomSeed == captured.randomSeed)
        #expect(rebuilt.ink.inkType == captured.ink.inkType)
        #expect(rebuilt.path.map(\.size) == captured.path.map(\.size))
        #expect(rebuilt.path.map(\.opacity) == captured.path.map(\.opacity))
        #expect(rebuilt.path.map(\.location) == captured.path.map(\.location))
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

    @Test func setPaletteRecolorsRenders() async throws {
        struct RedPaper: InkPalette {
            func paper(_: PaperTheme) -> RGBA8 { RGBA8(rgba: 0xFF00_00FF) }
            func templateLine(_ theme: PaperTheme) -> RGBA8 { FixturePalette().templateLine(theme) }
            func ink(_ color: InkColor, on theme: PaperTheme) -> RGBA8 { FixturePalette().ink(color, on: theme) }
        }
        let engine = PencilKitInkEngine(palette: FixturePalette())
        engine.setPalette(RedPaper())
        let image = try #require(await engine.render(page: RenderFixtures.blank, size: CGSize(width: 40, height: 50), scale: 1))
        #expect(RGBAPixels(image)[5, 5] == RGBA8(rgba: 0xFF00_00FF))
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
