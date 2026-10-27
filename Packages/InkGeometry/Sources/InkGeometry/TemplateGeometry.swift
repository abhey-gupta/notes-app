import CoreGraphics
import InkModel

/// Vector marks of a ``InkModel/PageTemplate`` in page space (origin top-left, points): the one definition
/// the screen (PencilKit page layers, thumbnails), the Metal background pass and PDF export draw (§5.3).
///
/// Lined and Cornell rules start ``top`` pt down; dots and grid lines sit on multiples of the spacing.
/// Cornell: 24 pt rules, cue column ``cornellCue`` wide (2.5 in) and a summary band ``cornellSummary``
/// tall (2 in) at the bottom.
public struct TemplateGeometry {
    /// Rules and grid lines, stroked at ``lineWidth``.
    public let lines: CGPath
    /// Dots, filled.
    public let dots: CGPath

    /// Hairline width (pt).
    public static let lineWidth: CGFloat = 0.75
    /// Dot radius (pt).
    public static let dotRadius: CGFloat = 1
    /// First rule of lined and Cornell pages (pt from the top).
    public static let top: CGFloat = 72
    /// Cornell rule spacing (pt).
    public static let cornellSpacing: CGFloat = 24
    /// Cornell cue column width: 2.5 in.
    public static let cornellCue: CGFloat = 180
    /// Cornell summary band height: 2 in.
    public static let cornellSummary: CGFloat = 144

    public var isEmpty: Bool {
        lines.isEmpty && dots.isEmpty
    }

    /// Marks for `template` on a `size` page. `leftExtension` is paper added left of the page's original
    /// origin (#129): columns of dots and grid lines stay on the original grid, moved right with the ink
    /// (`x ≡ leftExtension mod spacing`), and the Cornell cue column keeps its place beside the original left edge, so widening
    /// a page never moves its marks under the ink.
    public init(_ template: PageTemplate, size: CGSize, leftExtension: CGFloat = 0) {
        let lines = CGMutablePath()
        let dots = CGMutablePath()
        let shift = leftExtension.isFinite ? leftExtension : 0
        func rules(spacing: CGFloat, until bottom: CGFloat) {
            for y in stride(from: Self.top, to: bottom, by: spacing) {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        switch template {
        case .blank:
            break
        case let .lined(spacing):
            rules(spacing: Self.clamped(spacing), until: size.height)
        case let .dotted(spacing):
            let s = Self.clamped(spacing)
            let r = Self.dotRadius
            for y in stride(from: s, to: size.height, by: s) {
                for x in Self.columns(spacing: s, width: size.width, shift: shift) {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
            }
        case let .grid(spacing):
            let s = Self.clamped(spacing)
            for x in Self.columns(spacing: s, width: size.width, shift: shift) {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: s, to: size.height, by: s) {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
        case .cornell:
            let summary = max(size.height - Self.cornellSummary, Self.top)
            let cue = shift + min(Self.cornellCue, max(size.width - shift, 0) / 2)
            rules(spacing: Self.cornellSpacing, until: summary)
            lines.move(to: CGPoint(x: cue, y: Self.top - Self.cornellSpacing))
            lines.addLine(to: CGPoint(x: cue, y: summary))
            lines.move(to: CGPoint(x: 0, y: summary))
            lines.addLine(to: CGPoint(x: size.width, y: summary))
        }
        self.lines = lines
        self.dots = dots
    }

    /// Spacing ≥ 4 pt; 24 for a non-finite value from a damaged file.
    static func clamped(_ spacing: Float) -> CGFloat {
        spacing.isFinite ? CGFloat(max(spacing, 4)) : 24
    }

    /// Column positions `0 < x < width` on the grid `x ≡ shift (mod spacing)` (the original page's
    /// columns, `spacing, 2·spacing, …`, moved right by `shift`).
    public static func columns(spacing: CGFloat, width: CGFloat, shift: CGFloat) -> [CGFloat] {
        var first = shift.truncatingRemainder(dividingBy: spacing)
        if first < 0 {
            first += spacing
        }
        if first == 0 {
            first = spacing
        }
        return Array(stride(from: first, to: width, by: spacing))
    }

    /// Draws paper and marks into `context` (page space, origin top-left).
    public static func drawBackground(
        _ template: PageTemplate, size: CGSize, leftExtension: CGFloat = 0, paper: CGColor, line: CGColor, in context: CGContext
    ) {
        context.setFillColor(paper)
        context.fill(CGRect(origin: .zero, size: size))
        let marks = TemplateGeometry(template, size: size, leftExtension: leftExtension)
        guard !marks.isEmpty else { return }
        context.setStrokeColor(line)
        context.setLineWidth(lineWidth)
        context.addPath(marks.lines)
        context.strokePath()
        context.setFillColor(line)
        context.addPath(marks.dots)
        context.fillPath()
    }
}
