import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing
import UIKit

/// `PKStrokeCache`: loaded pages are converted off main (`prepare`), rebuilds reuse conversions.
@Suite(.timeLimit(.minutes(5)))
@MainActor
struct StrokeCacheTests {
    /// A page prepared off main reaches its canvas without converting strokes on main (zoom-open hitch).
    @Test func preparedPageConvertsNothingOnMain() async {
        let h = Harness()
        h.scroll(toY: 0)
        var pages = h.snapshots
        pages[0] = pages[0].appending(Self.strokes(3))
        await h.engine.prepare(pages[0])
        let converted = h.engine.strokeCache.mainConversions
        h.engine.setPages(pages)
        #expect(h.canvas(0)?.view.drawing.strokes.count == 3)
        #expect(h.engine.strokeCache.mainConversions == converted)
    }

    @Test func unpreparedPageConvertsOnMain() {
        let h = Harness()
        h.scroll(toY: 0)
        var pages = h.snapshots
        pages[0] = pages[0].appending(Self.strokes(3))
        let converted = h.engine.strokeCache.mainConversions
        h.engine.setPages(pages)
        #expect(h.engine.strokeCache.mainConversions == converted + 3)
    }

    /// Erasing rebuilds the canvas from the strokes it already converted.
    @Test func rebuildReusesConvertedStrokes() throws {
        let h = Harness()
        h.scroll(toY: 0)
        var pages = h.snapshots
        pages[0] = pages[0].appending(Self.strokes(3))
        h.engine.setPages(pages)
        let converted = h.engine.strokeCache.mainConversions
        try h.engine.apply(pages[0].page.removeEdit([RenderFixtures.strokeID(1)]), to: h.frames[0].id)
        #expect(h.canvas(0)?.view.drawing.strokes.count == 2)
        #expect(h.engine.strokeCache.mainConversions == converted)
    }

    /// Ink colors depend on the paper: a theme change converts again, in the new colors.
    @Test func themeChangeDropsPreparedStrokes() async throws {
        let h = Harness()
        h.scroll(toY: 0)
        var pages = h.snapshots
        pages[0] = pages[0].appending(Self.strokes(3))
        await h.engine.prepare(pages[0])
        h.engine.setTheme(.night)
        let converted = h.engine.strokeCache.mainConversions
        h.engine.setPages(pages)
        #expect(h.engine.strokeCache.mainConversions == converted + 3)
        let ink = try #require(h.canvas(0)?.view.drawing.strokes.first?.ink.color)
        #expect(RGBA8(ink) == RGBA8(UIColor(FixturePalette().ink(.primary, on: .night))))
    }

    private static func strokes(_ count: UInt8) -> [Stroke] {
        (1 ... count).map { RenderFixtures.line($0, from: CGPoint(x: 50, y: 50 + CGFloat($0) * 20), to: CGPoint(x: 300, y: 60)) }
    }
}
