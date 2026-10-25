import CoreGraphics
@testable import Export
import InkGeometry
import InkModel

/// Exact-geometry rendering of a page, independent of the exporter's curve fitting and PDF encoding:
/// raw `StrokeOutline` polygons filled straight into a bitmap, with the exporter's passes (paper,
/// template, highlighter multiply, ink).
enum ReferenceRenderer {
    static func bitmap(_ page: Page, scale: CGFloat, pageSize: CGSize = Notebook.a4Portrait) throws -> Bitmap {
        let palette = TestPalette()
        let theme = PaperTheme.white
        let height = Int(pageSize.height * scale)
        var bitmap = Bitmap(width: Int(pageSize.width * scale), height: height)
        try bitmap.draw { context in
            // Page space: origin top-left, y down, points.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            TemplateGeometry.drawBackground(
                page.template, size: pageSize, paper: palette.paper(theme), line: palette.templateLine(theme), in: context
            )

            func fill(_ stroke: Stroke, alpha: CGFloat) {
                let color = palette.ink(stroke.color, on: theme, keepsExactColors: false)
                let path = CGMutablePath()
                for contour in StrokeOutline(stroke: stroke).contours {
                    path.addLines(between: contour.map(\.cgPoint))
                    path.closeSubpath()
                }
                context.setFillColor(color.copy(alpha: color.alpha * alpha) ?? color)
                context.addPath(path)
                context.fillPath(using: .winding)
            }
            let drawn = page.strokes.filter { !$0.samples.isEmpty }
            context.setBlendMode(.multiply)
            for stroke in drawn where stroke.tool == .highlighter {
                fill(stroke, alpha: CGFloat(PenProfile.highlighter.opacity))
            }
            context.setBlendMode(.normal)
            for stroke in drawn where stroke.tool != .highlighter {
                fill(stroke, alpha: 1)
            }
        }
        return bitmap
    }
}

extension PDF {
    /// Renders a page at `scale` px/pt into sRGB RGBA8.
    func bitmap(_ index: Int, scale: CGFloat) throws -> Bitmap {
        let page = try page(index)
        let box = page.getBoxRect(.mediaBox)
        var bitmap = Bitmap(width: Int(box.width * scale), height: Int(box.height * scale))
        try bitmap.draw { context in
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
        }
        return bitmap
    }
}

/// Per-pixel difference between two renderings of one page, over the pixels either one inks.
struct ImageDiff: CustomStringConvertible {
    /// Channel difference (0...255) above which a pixel counts as visibly different.
    static let visibleThreshold = 64

    /// Pixels not paper-white in either image.
    var inkPixels = 0
    /// Ink pixels whose largest channel difference exceeds ``visibleThreshold``.
    var visiblePixels = 0
    /// Mean of the largest channel difference over ink pixels, 0...1.
    var meanError: Double = 0

    /// Fraction of ink pixels visibly different.
    var visibleFraction: Double {
        inkPixels > 0 ? Double(visiblePixels) / Double(inkPixels) : 0
    }

    var description: String {
        String(format: "visible %.3f%% of %d ink px, mean %.4f", 100 * visibleFraction, inkPixels, meanError)
    }

    init(_ a: Bitmap, _ b: Bitmap) {
        precondition(a.width == b.width && a.height == b.height, "bitmap sizes differ")
        var total = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in stride(from: 0, to: pa.count, by: 4) {
                    let isPaperA = pa[i] > 250 && pa[i + 1] > 250 && pa[i + 2] > 250
                    let isPaperB = pb[i] > 250 && pb[i + 1] > 250 && pb[i + 2] > 250
                    if isPaperA, isPaperB {
                        continue
                    }
                    var d = 0
                    for c in 0 ..< 3 {
                        d = max(d, abs(Int(pa[i + c]) - Int(pb[i + c])))
                    }
                    inkPixels += 1
                    total += d
                    if d > Self.visibleThreshold {
                        visiblePixels += 1
                    }
                }
            }
        }
        meanError = inkPixels > 0 ? Double(total) / Double(inkPixels) / 255 : 0
    }
}
