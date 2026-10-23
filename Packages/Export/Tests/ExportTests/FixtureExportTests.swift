@testable import Export
import FixtureGen
import Foundation
import InkModel
import Testing

/// Size and fidelity regressions over the realistic #40 fixture, seed 1 (#62): ~400 strokes/page of
/// cursive in one hand (ballpoint), with highlights, diagrams and a few pages in fountain or brush.
///
/// Debug builds (~100× slower geometry) check a few pages against the per-page share of the budget;
/// `swift test -c release --filter FixtureExportTests` runs all 100.
struct FixtureExportTests {
    static let fixture = FixtureGenerator(FixtureSpec(pages: 100, seed: 1))

    #if DEBUG
        static let sizePages = 4
        static let qualityPages = [0, 28]
    #else
        static let sizePages = 100
        static let qualityPages = [
            0, // ballpoint
            1, // ballpoint + highlighter
            4, // brush
            28, // fountain
        ]
    #endif

    /// ≤ 10 MB per 100 pages; ~46 MB before stroked centerlines (#62), ~7.7 MB after.
    @Test func exportStaysUnderTenMegabytesPerHundredPages() async throws {
        let pages = (0 ..< Self.sizePages).map(Self.fixture.page(at:))
        let clock = ContinuousClock()
        var data = Data()
        let elapsed = try await clock.measure {
            data = try await PDFExporter(palette: TestPalette()).pdfData(pages: pages, options: PDFExportOptions())
        }
        let line = String(
            format: "fixture seed 1, %d pages: %.2f MB, %.2f s\n",
            pages.count,
            Double(data.count) / 1e6,
            elapsed / .seconds(1)
        )
        FileHandle.standardError.write(Data(line.utf8))
        #expect(try PDF(data).pageCount == pages.count)
        #expect(data.count <= 100_000 * pages.count, "\(data.count) bytes")
    }

    /// Exported pages rasterized at 400 % against the exact outlines (no curve fitting, no PDF). The
    /// pre-#62 exporter scored 2.3–4.7 % visible and 0.017–0.035 mean on these pages; now ballpoint is at
    /// ~1 % / 0.02, fountain and brush (width steps) at ~3.3–4.5 % / ~0.03.
    @Test(arguments: qualityPages)
    func matchesExactGeometryAt400Percent(pageIndex: Int) async throws {
        let page = Self.fixture.page(at: pageIndex)
        let pdf = try await PDF(PDFExporter(palette: TestPalette()).pdfData(pages: [page], options: PDFExportOptions()))
        let diff = try ImageDiff(ReferenceRenderer.bitmap(page, scale: 4), pdf.bitmap(0, scale: 4))
        #expect(diff.inkPixels > 500_000)
        #expect(diff.visibleFraction <= 0.05, "\(diff)")
        #expect(diff.meanError <= 0.035, "\(diff)")
    }
}
