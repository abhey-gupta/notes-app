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
    /// Cap for ``strokes``: round for pens, butt for the highlighter's chisel.
    var cap: CGLineCap = .round
}

/// A page reduced to what the PDF needs, built off the drawing thread (outlines are the expensive part).
struct PageArt: Sendable {
    var page: PageID
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

        var art = PageArt(page: page.id, template: page.template)
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
        let highlighterOpacity = CGFloat(PenProfile.highlighter.opacity)

        for stroke in page.strokes where !stroke.samples.isEmpty {
            if stroke.tool == .brush, skipsBrush {
                continue
            }
            var color = resolve(stroke.color)
            let isHighlighter = stroke.tool == .highlighter
            if isHighlighter {
                color = color.copy(alpha: color.alpha * highlighterOpacity) ?? color
            }
            // Translucent ink must paint each pixel once: one stroke operation or one fill, no overlaps.
            let isOpaque = color.alpha >= 1
            let shape = StrokeShape(stroke: stroke, allowsOverlap: isOpaque)
            guard !shape.isEmpty else { continue }
            let run = InkRun(color: color, fills: shape.fills, strokes: shape.strokes, cap: shape.cap)
            if isHighlighter {
                art.highlights.append(run)
            } else if isOpaque, let last = art.ink.indices.last, art.ink[last].color == color, art.ink[last].cap == run.cap {
                // Opaque: the union looks the same as separate paints, with fewer PDF operators.
                art.ink[last].fills += run.fills
                art.ink[last].strokes += run.strokes
            } else {
                art.ink.append(run)
            }
        }
        return art
    }
}
