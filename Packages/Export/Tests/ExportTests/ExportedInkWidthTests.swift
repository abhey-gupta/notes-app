import CoreGraphics
@testable import Export
import InkGeometry
import InkModel
import Testing

/// Exported ink is as wide as PencilKit draws it on screen, not as wide as the stored point size:
/// a captured `.pen` point of size `w` paints `2 × w − 4` (``InkModel/InkNib``), and the PDF must too.
struct ExportedInkWidthTests {
    /// A horizontal captured-like stroke of constant point `size` and `azimuth`.
    static func stroke(ink: String, size: Float, tool: PenKind, azimuth: Float = 0) -> Stroke {
        let n = 80
        let samples = (0 ..< n).map { j in
            Sample(x: 40 + 320 * Float(j) / Float(n - 1), y: 100, force: 0.5, azimuth: azimuth, t: Float(j) / 240)
        }
        let points = samples.map { _ in PointRendering(width: size, height: size) }
        let rendering = StrokeRendering(ink: ink, randomSeed: 7, points: points)
        return Stroke(tool: tool, color: .primary, width: 2.5, samples: samples, rendering: rendering)
    }

    /// Mean ink thickness (pt) across the middle of the stroke: red-channel darkness summed per column,
    /// normalized by the ink's own darkness (the test palette's primary ink is not pure black).
    static func thickness(_ page: Page, scale: Int = 8) async throws -> Double {
        let options = PDFExportOptions(pageSize: CGSize(width: 400, height: 200))
        let data = try await PDFExporter(palette: TestPalette()).pdfData(pages: [page], options: options)
        let bitmap = try PDF(data).bitmap(0, scale: CGFloat(scale))
        let ink = TestPalette().ink(.primary, on: .white, keepsExactColors: false)
        let darkness = 1 - Double(ink.components?.first ?? 0)
        var total = 0.0
        let x0 = 120 * scale
        let x1 = 280 * scale
        for x in x0 ..< x1 {
            for y in 0 ..< bitmap.height {
                total += 1 - Double(bitmap.pixels[(y * bitmap.width + x) * 4]) / 255
            }
        }
        return total / Double(x1 - x0) / Double(scale) / darkness
    }

    @Test(arguments: [Float(2.8), 4, 10])
    func capturedPenExportsAtItsDrawnWidth(size: Float) async throws {
        let page = Page(strokes: [Self.stroke(ink: StrokeRendering.Ink.pen, size: size, tool: .ballpoint)])
        let expected = Double(2 * size - 4) // what PencilKit draws (InkWidthTests)
        let measured = try await Self.thickness(page)
        #expect(abs(measured - expected) <= 0.05 * expected + 0.02, "size \(size): \(measured) vs \(expected)")
    }

    @Test func capturedFountainPenExportsTheNibSideAcrossTheStroke() async throws {
        // Nib along the stroke (azimuth 0): the thin side; across it (π/2): the thick side.
        let thin = try await Self.thickness(Page(strokes: [Self.stroke(ink: StrokeRendering.Ink.fountainPen, size: 10, tool: .fountain)]))
        let thick = try await Self.thickness(Page(strokes: [
            Self.stroke(ink: StrokeRendering.Ink.fountainPen, size: 10, tool: .fountain, azimuth: .pi / 2),
        ]))
        #expect(abs(thin - 4) <= 0.2, "\(thin)")
        #expect(abs(thick - 16) <= 0.8, "\(thick)")
    }

    /// A stroke without a rendering (v1, fixtures) exports at its profile width.
    @Test func profileStrokeExportsAtItsWidth() async throws {
        var stroke = Self.stroke(ink: StrokeRendering.Ink.pen, size: 1, tool: .ballpoint)
        stroke = Stroke(tool: .ballpoint, color: .primary, width: 4, samples: stroke.samples)
        let expected = Double(4 * PenProfile.ballpoint.widthScale(force: 0.5, speed: 0, altitude: .pi / 2))
        let measured = try await Self.thickness(Page(strokes: [stroke]))
        #expect(abs(measured - expected) <= 0.05 * expected + 0.02, "\(measured) vs \(expected)")
    }
}
