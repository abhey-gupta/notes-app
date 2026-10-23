import InkModel

/// Resolves paper and ink colors for a theme (ARCHITECTURE.md §10).
///
/// Hex values live only in `DesignSystem`, which engines don't import; the app passes an adapter
/// over the design tokens to the engine's initializer. Implementations capture notebook settings
/// such as "Keep exact colors".
public protocol InkPalette: Sendable {
    /// Paper fill.
    func paper(_ theme: PaperTheme) -> RGBA8
    /// Template rules, dots and grid lines (`template.line`).
    func templateLine(_ theme: PaperTheme) -> RGBA8
    /// Ink as drawn on `theme`: semantic slots resolved, custom colors remapped on Night unless exact.
    func ink(_ color: InkColor, on theme: PaperTheme) -> RGBA8
}
