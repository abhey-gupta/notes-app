import CoreGraphics
@testable import Export
import Foundation
import InkModel
import Testing

struct PDFExporterTests {
    let exporter = PDFExporter(palette: TestPalette())

    /// Horizontal ballpoint line across the middle of the page.
    static func inkPage(template: PageTemplate = .blank, color: InkColor = .primary) -> Page {
        Page(template: template, strokes: [Fixtures.line(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 500, y: 400), color: color)])
    }

    @Test func pageCountAndMediaBox() async throws {
        let pages = (0 ..< 3).map { _ in Self.inkPage() }
        let pdf = try await PDF(exporter.pdfData(pages: pages, options: PDFExportOptions()))
        #expect(pdf.pageCount == 3)
        for i in 0 ..< 3 {
            #expect(try pdf.page(i).getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 595, height: 842))
        }

        let custom = try await PDF(exporter.pdfData(pages: pages, options: PDFExportOptions(pageSize: CGSize(width: 300, height: 200))))
        #expect(try custom.page(0).getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func pageSelection() async throws {
        let pages = (0 ..< 5).map { i in Page(strokes: (0 ..< i).map { _ in Fixtures.line(from: .zero, to: CGPoint(x: 50, y: 50)) }) }
        #expect(try await PDF(exporter.pdfData(pages: pages, options: PDFExportOptions(pages: .page(2)))).pageCount == 1)
        let range = try await PDF(exporter.pdfData(pages: pages, options: PDFExportOptions(pages: .range(1 ... 3))))
        #expect(range.pageCount == 3)
        // Page 1 of the range is notebook page 2 (two same-width strokes, merged into one opaque stroke run).
        let ops = try range.operatorCounts(0)
        #expect(ops.fills == 1) // paper
        #expect(ops.strokes == 1) // ink run

        await #expect(throws: PDFExportError.pageOutOfRange(5)) {
            try await exporter.pdfData(pages: pages, options: PDFExportOptions(pages: .range(3 ... 5)))
        }
        await #expect(throws: PDFExportError.pageOutOfRange(-1)) {
            try await exporter.pdfData(pages: pages, options: PDFExportOptions(pages: .page(-1)))
        }
        await #expect(throws: PDFExportError.noPages) {
            try await exporter.pdfData(pages: [], options: PDFExportOptions())
        }
        await #expect(throws: PDFExportError.invalidPageSize) {
            try await exporter.pdfData(pages: pages, options: PDFExportOptions(pageSize: .zero))
        }
    }

    @Test func pureVectorArtWithoutText() async throws {
        var rng = SplitMix64(state: 1)
        let page = Fixtures.densePage(&rng, strokes: 60)
        let pdf = try await PDF(exporter.pdfData(pages: [page], options: PDFExportOptions()))
        let ops = try pdf.operatorCounts(0)
        #expect(ops.text == 0)
        #expect(ops.images == 0)
        #expect(ops.fills + ops.strokes > 3)
        #expect(try !pdf.pageHasResource(0, "Font"))
        #expect(try !pdf.pageHasResource(0, "XObject"))
    }

    @Test func inkIsDrawnWhereTheStrokeIs() async throws {
        let pdf = try await PDF(exporter.pdfData(pages: [Self.inkPage()], options: PDFExportOptions()))
        let bitmap = try pdf.bitmap(0)
        #expect(bitmap[300, 400] == Pixel(0x1E, 0x21, 0x29)) // ink.primary, light
        #expect(bitmap[300, 300] == Pixel(255, 255, 255)) // paper
        #expect(bitmap[300, 500] == Pixel(255, 255, 255))
    }

    /// A page of a one-page PDF with a red band across its top half, drawn as page artwork.
    struct BandArtwork: PageArtwork, @unchecked Sendable {
        let page: CGPDFPage

        init() throws {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            let consumer = try #require(CGDataConsumer(data: data))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.setFillColor(srgb(0xFF0000))
            context.fill(CGRect(x: 0, y: 421, width: 595, height: 421))
            context.endPDFPage()
            context.closePDF()
            let provider = try #require(CGDataProvider(data: data))
            page = try #require(CGPDFDocument(provider)?.page(at: 1))
        }

        func draw(in context: CGContext, size: CGSize) {
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }

    @Test func inkIsFlattenedOntoPageArtworkKeptVector() async throws {
        let page = Self.inkPage()
        var exporter = exporter
        exporter.artwork = try [page.id: BandArtwork()]
        let pdf = try await PDF(exporter.pdfData(pages: [page, Self.inkPage()], options: PDFExportOptions()))
        let bitmap = try pdf.bitmap(0)
        #expect(bitmap[300, 200] == Pixel(255, 0, 0), "artwork's top half")
        #expect(bitmap[300, 600] == Pixel(255, 255, 255))
        #expect(bitmap[300, 400] == Pixel(0x1E, 0x21, 0x29), "ink on top")
        #expect(try pdf.operatorCounts(0).images == 0, "the original page stays vector")
        #expect(try pdf.bitmap(1)[300, 200] == Pixel(255, 255, 255), "pages without artwork are plain")
    }

    @Test func nightExportsOnWhiteWithLightPaletteByDefault() async throws {
        let options = PDFExportOptions(theme: .night)
        #expect(options.exportTheme == .white)
        let bitmap = try await PDF(exporter.pdfData(pages: [Self.inkPage()], options: options)).bitmap(0)
        #expect(bitmap[300, 300] == Pixel(255, 255, 255))
        #expect(bitmap[300, 400] == Pixel(0x1E, 0x21, 0x29))
    }

    @Test func nightExportAsShownKeepsDarkPaperAndPalette() async throws {
        let options = PDFExportOptions(theme: .night, exportsAsShown: true)
        #expect(options.exportTheme == .night)
        let bitmap = try await PDF(exporter.pdfData(pages: [Self.inkPage()], options: options)).bitmap(0)
        #expect(bitmap[300, 300] == Pixel(0x1B, 0x1C, 0x1F))
        #expect(bitmap[300, 400] == Pixel(0xE9, 0xE8, 0xE4))
    }

    @Test func creamIsKept() async throws {
        let bitmap = try await PDF(exporter.pdfData(pages: [Self.inkPage()], options: PDFExportOptions(theme: .cream))).bitmap(0)
        #expect(bitmap[300, 300] == Pixel(0xF6, 0xF0, 0xE1))
    }

    @Test func highlighterMultipliesBeneathInk() async throws {
        let ink = Fixtures.line(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 500, y: 400))
        // Added after the ink (higher z), but the highlighter pass still goes first.
        let highlight = Fixtures.line(
            from: CGPoint(x: 300, y: 300), to: CGPoint(x: 300, y: 500), tool: .highlighter, color: Fixtures.yellow, width: 20
        )
        let page = Page(strokes: [ink, highlight])
        let options = PDFExportOptions(theme: .night, exportsAsShown: true)
        let bitmap = try await PDF(exporter.pdfData(pages: [page], options: options)).bitmap(0)

        // Over Night paper, multiply darkens: yellow × #1B1C1F at 55 % stays near the paper color, where
        // normal blending would turn it mid-yellow (~118, 105, 39).
        let onPaper = bitmap[300, 350]
        #expect(onPaper.r <= 0x1B + 2 && onPaper.g <= 0x1C + 2 && onPaper.b <= 0x1F)
        #expect(onPaper.b < 0x1F - 4) // but it did draw (blue × 0.2)
        // Ink stays on top, untouched by the highlighter.
        #expect(bitmap[300, 400] == Pixel(0xE9, 0xE8, 0xE4))
        // Highlighter on white paper: yellow at 55 %.
        let light = try await PDF(exporter.pdfData(pages: [page], options: PDFExportOptions())).bitmap(0)
        let tint = light[300, 350]
        #expect(tint.r == 255 && abs(tint.g - 232) <= 2 && abs(tint.b - 143) <= 2)
    }

    @Test func templatesAreVector() async throws {
        let templates: [PageTemplate] = [.blank, .lined(spacing: 24), .dotted(spacing: 20), .grid(spacing: 20), .cornell]
        let pages = templates.map { Page(template: $0) }
        let pdf = try await PDF(exporter.pdfData(pages: pages, options: PDFExportOptions()))
        #expect(pdf.pageCount == templates.count)
        let blank = try pdf.bitmap(0)
        #expect(blank.minLuma(x: 0 ... 594, y: 40 ... 60) == 255)
        // Lined: first rule 72 pt down (same as the screen: InkGeometry.TemplateGeometry).
        let lined = try pdf.bitmap(1)
        #expect(lined.minLuma(x: 200 ... 210, y: 71 ... 72) < 200)
        #expect(lined.minLuma(x: 200 ... 210, y: 50 ... 65) == 255)
        // Dotted: dots on multiples of 20 pt.
        let dotted = try pdf.bitmap(2)
        #expect(dotted.minLuma(x: 19 ... 20, y: 19 ... 20) < 200)
        #expect(dotted.minLuma(x: 25 ... 35, y: 25 ... 35) == 255)
        // Grid: vertical and horizontal rules every 20 pt.
        let grid = try pdf.bitmap(3)
        #expect(grid.minLuma(x: 19 ... 20, y: 100 ... 105) < 140)
        #expect(grid.minLuma(x: 100 ... 105, y: 19 ... 20) < 140)
        // Cornell: cue column 2.5 in from the left, summary band 2 in tall.
        let cornell = try pdf.bitmap(4)
        #expect(cornell.minLuma(x: 179 ... 180, y: 300 ... 302) < 200)
        #expect(cornell.minLuma(x: 400 ... 410, y: 697 ... 698) < 200)
        #expect(cornell.minLuma(x: 400 ... 410, y: 710 ... 830) == 255)
        for i in 1 ..< templates.count {
            #expect(try pdf.operatorCounts(i).text == 0)
        }
    }

    @Test func brushRasterHookCompositesImageBeneathInk() async throws {
        let rasterizer = RecordingRasterizer(returnsImage: true)
        let exporter = PDFExporter(palette: TestPalette(), brushRasterizer: rasterizer)
        let brush = Fixtures.line(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 250, y: 100), tool: .brush, color: .semantic(.blue))
        let ink = Fixtures.line(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 200))
        let pages = [Page(strokes: [ink, brush]), Self.inkPage()]
        let pdf = try await PDF(exporter.pdfData(pages: pages, options: PDFExportOptions()))

        let requests = rasterizer.recorded
        #expect(requests.count == 1) // page 2 has no brush strokes
        #expect(requests.first?.strokes.map(\.id) == [brush.id])
        #expect(requests.first?.scale == 2)
        #expect(requests.first?.pageSize == Notebook.a4Portrait)
        #expect(requests.first?.colors == [srgb(0x2C4FD6)])

        #expect(try pdf.pageHasResource(0, "XObject"))
        #expect(try pdf.operatorCounts(0).images == 1)
        #expect(try !pdf.pageHasResource(1, "XObject"))
        let bitmap = try pdf.bitmap(0)
        #expect(bitmap[20, 20] == Pixel(255, 0, 0)) // image's top-left quarter lands top-left
        #expect(bitmap[500, 800] == Pixel(255, 255, 255))
        #expect(bitmap[100, 150] == Pixel(0x1E, 0x21, 0x29)) // ink above the image
        // The brush stroke itself was not also drawn as vector: only the raster's red is at its spot.
        #expect(bitmap[200, 100] == Pixel(255, 0, 0))
    }

    @Test func brushFallsBackToVectorWithoutRaster() async throws {
        let rasterizer = RecordingRasterizer(returnsImage: false)
        let exporter = PDFExporter(palette: TestPalette(), brushRasterizer: rasterizer)
        let brush = Fixtures.line(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 250, y: 100), tool: .brush, color: .semantic(.blue))
        let pdf = try await PDF(exporter.pdfData(pages: [Page(strokes: [brush])], options: PDFExportOptions()))
        #expect(rasterizer.recorded.count == 1)
        #expect(try !pdf.pageHasResource(0, "XObject"))
        #expect(try pdf.bitmap(0)[150, 100] == Pixel(0x2C, 0x4F, 0xD6))
    }

    @Test func exportPDFWritesTempFileAndReportsProgress() async throws {
        let progress = ProgressLog()
        let pages = (0 ..< 20).map { _ in Self.inkPage(template: .dotted(spacing: 20)) }
        let url = try await exporter.exportPDF(
            pages: pages,
            options: PDFExportOptions(title: "Physics: week 3/4"),
            progress: { progress.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "Physics- week 3-4.pdf")
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let pdf = try PDF(Data(contentsOf: url))
        #expect(pdf.pageCount == 20)
        #expect(pdf.document.info.flatMap { info in
            var title: CGPDFStringRef?
            return CGPDFDictionaryGetString(info, "Title", &title) ? title.flatMap(CGPDFStringCopyTextString) as String? : nil
        } == "Physics: week 3/4")
        let values = progress.values
        #expect(values.count == 20)
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    @Test func fileNames() {
        #expect(PDFExporter.fileName(for: nil) == "Notebook.pdf")
        #expect(PDFExporter.fileName(for: "  ") == "Notebook.pdf")
        #expect(PDFExporter.fileName(for: "../etc") == "Notebook.pdf")
        #expect(PDFExporter.fileName(for: ".hidden") == "Notebook.pdf")
        #expect(PDFExporter.fileName(for: "Lecture\n1") == "Lecture-1.pdf")
    }

    @Test func cancellationStopsTheExport() async throws {
        var rng = SplitMix64(state: 3)
        let pages = (0 ..< 40).map { _ in Fixtures.densePage(&rng, strokes: 50) }
        let exporter = exporter
        let task = Task {
            try await exporter.pdfData(pages: pages, options: PDFExportOptions())
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

/// Thread-safe progress recorder. Unchecked: `values` is guarded by `lock`.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Double] = []

    var values: [Double] {
        lock.withLock { log }
    }

    func append(_ value: Double) {
        lock.withLock { log.append(value) }
    }
}
