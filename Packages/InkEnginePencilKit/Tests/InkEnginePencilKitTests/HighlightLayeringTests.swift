import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing
import UIKit

/// Highlights sit beneath other ink everywhere PencilKit draws a page (#120).
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct HighlightLayeringTests {
    /// Ink along y 100, then a wide highlight across it.
    private static let ink = RenderFixtures.line(1, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 100), width: 4)
    private static let highlight = RenderFixtures.line(
        2, from: CGPoint(x: 80, y: 100), to: CGPoint(x: 420, y: 100), tool: .highlighter, color: .semantic(.red), width: 24
    )

    private static func page(_ strokes: [Stroke]) -> PageSnapshot {
        PageSnapshot(page: Page(id: RenderFixtures.pageID(1), template: .blank), size: RenderFixtures.pageSize).appending(strokes)
    }

    private static func isClose(_ a: RGBA8, _ b: RGBA8) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 6 && abs(Int(a.g) - Int(b.g)) <= 6 && abs(Int(a.b) - Int(b.b)) <= 6
    }

    @Test func layeredMovesHighlightsFirstKeepingOrder() {
        let items = ["a", "H1", "b", "H2", "c"]
        #expect(InkLayering.layered(items) { $0.hasPrefix("H") } == ["H1", "H2", "a", "b", "c"])
    }

    @Test(arguments: [PaperTheme.white, .night])
    func highlightOverInkLeavesInkUnchanged(theme: PaperTheme) async throws {
        let engine = PencilKitInkEngine(palette: FixturePalette())
        engine.setTheme(theme)
        let size = RenderFixtures.pageSize
        let plain = try #require(await engine.render(page: Self.page([Self.ink]), size: size, scale: 2))
        let marked = try #require(await engine.render(page: Self.page([Self.ink, Self.highlight]), size: size, scale: 2))
        let inkPixel = RGBAPixels(plain)[500, 200]
        #expect(Self.isClose(RGBAPixels(marked)[500, 200], inkPixel), "ink shows through: \(RGBAPixels(marked)[500, 200]) vs \(inkPixel)")
        #expect(RGBAPixels(marked)[500, 190] != RGBAPixels(plain)[500, 190], "the highlight still paints around the ink")
    }

    @Test func pendingHighlightDrawsBeneathStoredInk() {
        let pk = PencilKitConversion.pkStroke(from: Self.highlight, color: .red)
        let job = RenderJob(page: Self.page([Self.ink]), palette: FixturePalette(), theme: .white, pending: [pk])
        #expect(job.drawing().strokes.map(\.ink.inkType) == [.marker, .pen])
    }

    @Test func committedHighlightOverInkMovesBeneathIt() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .pen(.highlighter), color: .semantic(.red), width: 16))
        // Across stroke 9 (page 2, y 50).
        h.userDraws(RenderFixtures.line(2, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 320, y: 50), tool: .highlighter, width: 16))
        let (stroke, page) = try #require(h.recorder.commits.first)
        let canvas = try #require(h.canvas(1))
        #expect(canvas.ids == [RenderFixtures.strokeID(9), stroke.id], "on top while it is drawn")

        let rebuilds = h.engine.rebuildCount
        let snapshot = try #require(h.engine.snapshots[page])
        h.engine.apply(snapshot.page.addEdit([stroke]), to: page)
        #expect(h.engine.rebuildCount == rebuilds + 1)
        #expect(canvas.ids == [stroke.id, RenderFixtures.strokeID(9)])
        #expect(canvas.view.drawing.strokes.map(\.ink.inkType) == [.marker, .pen])

        // Undo and redo keep ids and drawing in step.
        try h.engine.apply(#require(h.engine.snapshots[page]).page.removeEdit([stroke.id]), to: page)
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        h.engine.apply(.add([PlacedStroke(index: 1, stroke: stroke)]), to: page)
        #expect(canvas.ids == [stroke.id, RenderFixtures.strokeID(9)])
        #expect(canvas.view.drawing.strokes.count == 2)
    }

    @Test func committedHighlightAwayFromInkKeepsCanvas() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .pen(.highlighter), color: .semantic(.red), width: 16))
        h.userDraws(RenderFixtures.line(2, from: CGPoint(x: 40, y: 400), to: CGPoint(x: 320, y: 400), tool: .highlighter, width: 16))
        let (stroke, page) = try #require(h.recorder.commits.first)
        let rebuilds = h.engine.rebuildCount
        let snapshot = try #require(h.engine.snapshots[page])
        h.engine.apply(snapshot.page.addEdit([stroke]), to: page)
        #expect(h.engine.rebuildCount == rebuilds, "nothing it covers: no rebuild")
        #expect(h.canvas(1)?.view.drawing.strokes.count == 2)
        #expect(h.canvas(1)?.ids.count == 2)

        // The next stroke still lands in step with the ids.
        h.engine.setTool(ToolConfiguration(tool: .pen(.ballpoint)))
        h.userDraws(RenderFixtures.line(3, from: CGPoint(x: 40, y: 600), to: CGPoint(x: 320, y: 600)))
        #expect(h.recorder.commits.count == 2)
        #expect(h.canvas(1)?.ids.count == 3)
    }

    @Test func addedHighlightLayersBeneathAndStaysStable() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let snapshot = try #require(h.engine.snapshots[page])
        try h.engine.apply(snapshot.page.addEdit([Self.highlight]), to: page)
        let canvas = try #require(h.canvas(1))
        #expect(canvas.ids == [Self.highlight.id, RenderFixtures.strokeID(9)])
        h.engine.rebuildCanvas(canvas)
        #expect(canvas.ids == [Self.highlight.id, RenderFixtures.strokeID(9)], "stable across rebuilds")
    }

    @Test func liftedHighlightReturnsBeneathInk() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let mark = RenderFixtures.line(2, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 320, y: 50), tool: .highlighter, width: 16)
        try h.engine.apply(#require(h.engine.snapshots[page]).page.addEdit([mark]), to: page)
        let canvas = try #require(h.canvas(1))
        h.engine.setSelectionPreview(SelectionPreview(page: page, strokes: [mark.id]))
        #expect(canvas.ids == [RenderFixtures.strokeID(9)])
        #expect(h.engine.selection.lifted.contents != nil)
        let move = CGAffineTransform(translationX: 0, y: 20)
        try h.engine.apply(#require(h.engine.snapshots[page]).page.transformEdit([mark.id], by: move), to: page)
        h.engine.setSelectionPreview(nil)
        #expect(canvas.ids == [mark.id, RenderFixtures.strokeID(9)])
        #expect(canvas.view.drawing.strokes.map(\.ink.inkType) == [.marker, .pen])
    }
}
