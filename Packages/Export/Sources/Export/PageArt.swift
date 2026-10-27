import CoreGraphics
import InkGeometry
import InkModel

/// One painted shape in one color: the union of filled outlines (nonzero) and stroked centerlines.
struct InkRun: Sendable {
    var color: CGColor
    /// Filled outline contours (fitted cubics).
    var fills: [CubicContour] = []
    /// Centerline pieces stroked with round joins and ``cap``.
    var strokes: [StrokedPath] = []
    /// Cap for ``strokes`` (round for pens).
    var cap: CGLineCap = .round
}

/// A page reduced to what the PDF needs, built off the drawing thread (outlines are the expensive part).
struct PageArt: Sendable {
    var template: PageTemplate
    /// One run per highlighter stroke (each multiplies separately, like on screen).
    var highlights: [InkRun] = []
    /// Brush strokes as an image under the ink, if a rasterizer provided one.
    var brushImage: CGImage?
    /// Pen ink (and brush, without a raster), bottom to top; consecutive strokes of one opaque color share
    /// a run.
    var ink: [InkRun] = []

    /// Splits `page` into passes and reduces each stroke to curves (``StrokeShape``).
    static func build(
        _ page: Page,
        options: PDFExportOptions,
        palette: any PDFPalette,
        rasterizer: (any BrushRasterizer)?,
        rasterScale: CGFloat
    ) async throws -> PageArt {
        let theme = options.exportTheme
        var colors: [InkColor: CGColor] = [:]
        func resolve(_ color: InkColor) -> CGColor {
            if let cached = colors[color] {
                return cached
            }
            let resolved = palette.ink(color, on: theme, keepsExactColors: options.keepsExactColors)
            colors[color] = resolved
            return resolved
        }

        var art = PageArt(template: page.template)
        if let rasterizer {
            let brushes = page.strokes.filter { $0.tool == .brush && !$0.samples.isEmpty }
            if !brushes.isEmpty {
                art.brushImage = try await rasterizer.rasterize(BrushRasterRequest(
                    pageID: page.id,
                    strokes: brushes,
                    colors: brushes.map { resolve($0.color) },
                    theme: theme,
                    pageSize: options.pageSize,
                    scale: rasterScale
                ))
            }
        }
        let skipsBrush = art.brushImage != nil

        for stroke in page.strokes where !stroke.samples.isEmpty {
            if stroke.tool == .brush, skipsBrush {
                continue
            }
            let color = resolve(stroke.color)
            if stroke.tool == .highlighter {
                if let run = highlight(stroke, color: color) {
                    art.highlights.append(run)
                }
                continue
            }
            // Translucent ink must paint each pixel once: one stroke operation or one fill, no overlaps.
            let isOpaque = color.alpha >= 1
            let shape = StrokeShape(stroke: stroke, allowsOverlap: isOpaque)
            guard !shape.isEmpty else { continue }
            let run = InkRun(color: color, fills: shape.fills, strokes: shape.strokes, cap: shape.cap)
            if isOpaque, let last = art.ink.indices.last, art.ink[last].color == color, art.ink[last].cap == run.cap {
                // Opaque: the union looks the same as separate paints, with fewer PDF operators.
                art.ink[last].fills += run.fills
                art.ink[last].strokes += run.strokes
            } else {
                art.ink.append(run)
            }
        }
        return art
    }

    /// The band the screen draws (#120) at the highlighter's alpha: its polygons merged with their rounded
    /// rim (the nib's corners) into one outline, filled once, so each pixel paints once.
    private static func highlight(_ stroke: Stroke, color: CGColor) -> InkRun? {
        let band = HighlightBand(stroke: stroke)
        guard !band.polygons.isEmpty else { return nil }
        let path = CGMutablePath()
        for polygon in band.polygons {
            path.addLines(between: polygon.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            path.closeSubpath()
        }
        let rim = path.copy(strokingWithWidth: CGFloat(2 * band.cornerRadius), lineCap: .round, lineJoin: .round, miterLimit: 10)
        let fills = CubicContour.contours(of: path.union(rim, using: .winding))
        guard !fills.isEmpty else { return nil }
        let alpha = color.alpha * CGFloat(PenProfile.highlighter.opacity)
        return InkRun(color: color.copy(alpha: alpha) ?? color, fills: fills)
    }
}
