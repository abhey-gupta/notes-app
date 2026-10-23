import CoreGraphics
import InkGeometry
import InkModel

/// One filled shape: the union (nonzero) of some strokes' outlines as fitted curves, in one color.
struct FillRun: Sendable {
    var color: CGColor
    var contours: [CubicContour]
}

/// A page reduced to what the PDF needs, built off the drawing thread (outlines are the expensive part).
struct PageArt: Sendable {
    var template: PageTemplate
    /// One run per highlighter stroke (each multiplies separately, like on screen).
    var highlights: [FillRun] = []
    /// Brush strokes as an image under the ink, if a rasterizer provided one.
    var brushImage: CGImage?
    /// Pen ink (and brush, without a raster), bottom to top; consecutive strokes of one opaque color share
    /// a run.
    var ink: [FillRun] = []

    /// Splits `page` into passes and computes outlines (fitted to cubics: ~6× fewer PDF coordinates).
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
        let highlighterOpacity = CGFloat(PenProfile.highlighter.opacity)

        for stroke in page.strokes where !stroke.samples.isEmpty {
            if stroke.tool == .brush, skipsBrush {
                continue
            }
            let contours = StrokeOutline(stroke: stroke).contours.compactMap { CurveFit.fit(closed: $0) }
            guard !contours.isEmpty else { continue }
            let color = resolve(stroke.color)
            if stroke.tool == .highlighter {
                art.highlights.append(FillRun(color: color.copy(alpha: color.alpha * highlighterOpacity) ?? color, contours: contours))
            } else if color.alpha >= 1, let last = art.ink.indices.last, art.ink[last].color == color {
                // Opaque: the union looks the same as separate fills, with fewer PDF operators.
                art.ink[last].contours += contours
            } else {
                art.ink.append(FillRun(color: color, contours: contours))
            }
        }
        return art
    }
}
