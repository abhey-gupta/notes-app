import CoreGraphics
import InkModel

/// Concrete colors for export. Hex values live only in `DesignSystem` (ARCHITECTURE.md §10), which is
/// SwiftUI/UIKit-only, so the headless `Export` package takes them through this protocol; the app adapts
/// `DesignSystem.PaperTheme` (paper, `templateLine`, `ink(_:)`, `adapt(_:keepExact:)`) to it.
///
/// Every method receives the *export* theme (``PDFExportOptions/exportTheme``), not the notebook's, so
/// a Night notebook exported on white resolves semantic ink to the light palette.
public protocol PDFPalette: Sendable {
    /// Page background.
    func paper(_ theme: PaperTheme) -> CGColor
    /// Template lines and dots.
    func templateLine(_ theme: PaperTheme) -> CGColor
    /// A stroke color as it appears on `theme`: semantic slots resolved per theme, custom colors
    /// lightness-remapped on dark paper unless `keepsExactColors`. Pen opacity (highlighter) is applied
    /// by the exporter on top of this.
    func ink(_ color: InkColor, on theme: PaperTheme, keepsExactColors: Bool) -> CGColor
}

/// Everything a ``BrushRasterizer`` needs to draw one page's brush strokes.
public struct BrushRasterRequest: Sendable {
    /// Page being exported.
    public var pageID: PageID
    /// Brush strokes, bottom to top.
    public var strokes: [Stroke]
    /// Resolved color per stroke (parallel to ``strokes``).
    public var colors: [CGColor]
    /// Export paper theme.
    public var theme: PaperTheme
    /// Page size in points; the image must cover exactly this rect.
    public var pageSize: CGSize
    /// Pixels per point (``PDFExporter/brushRasterScale``).
    public var scale: CGFloat
}

/// Rasterizes soft-edged brush strokes, which look wrong as hard vector fills (§9). The app implements this
/// with `engine.render`; without one (or when it returns `nil`) brush strokes export as vector fills.
public protocol BrushRasterizer: Sendable {
    /// Renders the request's strokes onto a transparent image of `pageSize × scale` pixels, page space with
    /// the origin top-left. The exporter composites it beneath the vector ink.
    /// - Returns: The image, or `nil` to fall back to vector fills for this page.
    func rasterize(_ request: BrushRasterRequest) async throws -> CGImage?
}
