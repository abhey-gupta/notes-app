import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkGeometry
import InkModel
import PencilKit
import Testing
import UIKit

/// Shared fixtures of the highlighter suites (#120).
enum HighlighterFixtures {
    /// Ink along y 100, then a wide highlight across it.
    static let ink = RenderFixtures.line(1, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 100), width: 4)
    static let highlight = RenderFixtures.line(
        2, from: CGPoint(x: 80, y: 100), to: CGPoint(x: 420, y: 100), tool: .highlighter, color: .semantic(.red), width: 24
    )
    static let tool = ToolConfiguration(tool: .pen(.highlighter), color: .semantic(.red), width: 16)

    static func page(_ strokes: [Stroke]) -> PageSnapshot {
        PageSnapshot(page: Page(id: RenderFixtures.pageID(1), template: .blank), size: RenderFixtures.pageSize).appending(strokes)
    }

    static func isClose(_ a: RGBA8, _ b: RGBA8, within tolerance: Int = 6) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance && abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    /// Rows (pt) above 25 % alpha in the column at `x` (pt) of a 2 px/pt image.
    static func bandHeight(_ px: RGBAPixels, x: CGFloat, height: Int) -> Double {
        var rows = 0
        for y in 0 ..< height where px[Int(x * 2), y].a > 64 {
            rows += 1
        }
        return Double(rows) / 2
    }

    static func bandWidth(_ px: RGBAPixels, y: CGFloat, width: Int) -> Double {
        var columns = 0
        for x in 0 ..< width where px[x, Int(y * 2)].a > 64 {
            columns += 1
        }
        return Double(columns) / 2
    }
}

/// The highlighter (#120): a constant-width, flat-ended, translucent band the engine draws itself beneath
/// all other ink, one fill per stroke, in rasters, thumbnails and the popover preview.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct HighlighterLookTests {
    typealias Fixtures = HighlighterFixtures

    @Test(arguments: [PaperTheme.white, .night])
    func highlightOverInkLeavesInkUnchanged(theme: PaperTheme) async throws {
        let engine = PencilKitInkEngine(palette: FixturePalette())
        engine.setTheme(theme)
        let size = RenderFixtures.pageSize
        let plain = try #require(await engine.render(page: Fixtures.page([Fixtures.ink]), size: size, scale: 2))
        let marked = try #require(await engine.render(page: Fixtures.page([Fixtures.ink, Fixtures.highlight]), size: size, scale: 2))
        let inkPixel = RGBAPixels(plain)[500, 200]
        #expect(
            Fixtures.isClose(RGBAPixels(marked)[500, 200], inkPixel),
            "ink shows through: \(RGBAPixels(marked)[500, 200]) vs \(inkPixel)"
        )
        // Beside the ink the paper is tinted: red at the band's alpha over the paper.
        let paper = FixturePalette().paper(theme)
        let red = FixturePalette().ink(.semantic(.red), on: theme)
        let a = Highlight.opacity
        let expected = RGBA8(
            r: UInt8((CGFloat(paper.r) * (1 - a) + CGFloat(red.r) * a).rounded()),
            g: UInt8((CGFloat(paper.g) * (1 - a) + CGFloat(red.g) * a).rounded()),
            b: UInt8((CGFloat(paper.b) * (1 - a) + CGFloat(red.b) * a).rounded()), a: 255
        )
        #expect(Fixtures.isClose(RGBAPixels(marked)[500, 180], expected), "tint \(RGBAPixels(marked)[500, 180]) vs \(expected)")
        #expect(RGBAPixels(marked)[500, 180] != RGBAPixels(plain)[500, 180])
    }

    @Test func bandIsConstantWidthWithFlatEnds() throws {
        let job = RenderJob(page: Fixtures.page([Fixtures.highlight]), palette: FixturePalette(), theme: .white)
        let px = try RGBAPixels(#require(job.ink(scale: 2)))
        let height = Int(RenderFixtures.pageSize.height * 2)
        #expect(abs(Fixtures.bandHeight(px, x: 250, height: height) - 24) <= 1)
        // Upright flat ends half the nib's thickness (6 pt) past the end samples, full height to the edge.
        #expect(Fixtures.bandHeight(px, x: 422.5, height: height) >= 23)
        #expect(Fixtures.bandHeight(px, x: 423.5, height: height) == 0)
        #expect(Fixtures.bandHeight(px, x: 77.5, height: height) >= 23)
        #expect(Fixtures.bandHeight(px, x: 76.5, height: height) == 0)
        // Drawn downwards it is the nib's thickness: the nib stays upright, whatever the Pencil does.
        let down = RenderFixtures.line(3, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 500), tool: .highlighter, width: 24)
        let vertical =
            try RGBAPixels(#require(RenderJob(page: Fixtures.page([down]), palette: FixturePalette(), theme: .white).ink(scale: 2)))
        #expect(abs(Fixtures.bandWidth(vertical, y: 350, width: Int(RenderFixtures.pageSize.width * 2)) - 6) <= 1)
    }

    @Test func crossingItselfDoesNotDarken() throws {
        let there = Fixtures.highlight.samples
        let back = there.reversed().map { Sample(x: $0.x, y: $0.y, t: $0.t + 2) }
        let doubled = Stroke(id: RenderFixtures.strokeID(4), tool: .highlighter, color: .semantic(.red), width: 24, samples: there + back)
        let single =
            try RGBAPixels(#require(RenderJob(page: Fixtures.page([Fixtures.highlight]), palette: FixturePalette(), theme: .white)
                        .ink(scale: 2)))
        let twice =
            try RGBAPixels(#require(RenderJob(page: Fixtures.page([doubled]), palette: FixturePalette(), theme: .white).ink(scale: 2)))
        #expect(abs(Int(twice[500, 200].a) - Int(single[500, 200].a)) <= 2)
        #expect(abs(Int(single[500, 200].a) - Int((Highlight.opacity * 255).rounded())) <= 2)
        // Two strokes do add up, as in the PDF.
        let pair = try RGBAPixels(#require(RenderJob(
            page: Fixtures.page([Fixtures.highlight, doubled]),
            palette: FixturePalette(),
            theme: .white
        ).ink(scale: 2)))
        #expect(pair[500, 200].a > single[500, 200].a + 40)
    }

    @Test func aDotLeavesTheNibsFootprint() throws {
        let dot = Stroke(
            id: RenderFixtures.strokeID(5),
            tool: .highlighter,
            color: .semantic(.red),
            width: 24,
            samples: [Sample(x: 300, y: 300)]
        )
        let path = try #require(Highlight.path(of: dot))
        #expect(path.boundingBox == CGRect(x: 297, y: 288, width: 6, height: 24))
        #expect(Highlight.path(of: Stroke(tool: .highlighter, color: .primary, width: 24, samples: [])) == nil)
    }

    /// A page's raster leaves highlights to the page view's layers; thumbnails and the lifted image have them.
    @Test func rasterIsInkOnly() throws {
        let inkOnly = RenderJob(page: Fixtures.page([Fixtures.highlight]), palette: FixturePalette(), theme: .white, layers: .ink)
        #expect(inkOnly.isEmpty)
        let both = RenderJob(
            page: Fixtures.page([Fixtures.ink, Fixtures.highlight]),
            palette: FixturePalette(),
            theme: .white,
            layers: .ink
        )
        let px = try RGBAPixels(#require(both.ink(scale: 2)))
        #expect(px[500, 180].a == 0, "no band in the ink raster")
        #expect(px[500, 200].a > 0)
        let all = try RGBAPixels(#require(RenderJob(
            page: Fixtures.page([Fixtures.ink, Fixtures.highlight]),
            palette: FixturePalette(),
            theme: .white
        ).ink(scale: 2)))
        #expect(all[500, 180].a > 0)
        #expect(all[500, 200].a == 255, "ink on top, opaque")
    }

    @Test func previewDrawsTheBand() throws {
        let spec = InkPreview.Spec(kind: .highlighter, width: 16, color: RGBA8(r: 0xFF, g: 0xD6, b: 0x33), pressure: false)
        let size = CGSize(width: 296, height: 72)
        let image = try #require(InkPreview.image(spec, size: size, scale: 2).cgImage)
        let px = RGBAPixels(image)
        var alphas: [UInt8] = []
        for y in 0 ..< image.height where px[image.width / 2, y].a > 0 {
            alphas.append(px[image.width / 2, y].a)
        }
        let band = Int((Highlight.opacity * 255).rounded())
        #expect(alphas.contains { abs(Int($0) - band) <= 2 })
        #expect(alphas.allSatisfy { Int($0) <= band + 2 }, "never darker where the band overlaps itself: \(alphas)")
    }
}
