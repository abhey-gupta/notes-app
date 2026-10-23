import CoreGraphics
import InkModel

/// Vector geometry of a ``InkModel/PageTemplate`` in page space (origin top-left, points).
///
/// Provisional: the engine's procedural template pass (§3.3, §5.3) isn't written yet. When it lands this
/// layout should move to `InkGeometry` so screen and PDF share one definition.
struct TemplateArt {
    /// Template stroke width (1 pt, like the mock's 1 px rules).
    static let lineWidth: CGFloat = 1
    /// Dot radius (`Tokens.Size.templateDot`).
    static let dotRadius: CGFloat = 1.1
    /// Cornell cue column, fraction of page width.
    static let cornellCueFraction: CGFloat = 0.3
    /// Cornell summary area, fraction of page height.
    static let cornellSummaryFraction: CGFloat = 0.2
    /// Cornell rule spacing.
    static let cornellSpacing: CGFloat = 24

    /// Lines to stroke at ``lineWidth``.
    let lines = CGMutablePath()
    /// Dots to fill.
    let dots = CGMutablePath()

    var isEmpty: Bool {
        lines.isEmpty && dots.isEmpty
    }

    init(_ template: PageTemplate, pageSize size: CGSize) {
        switch template {
        case .blank:
            break
        case let .lined(spacing):
            let s = Self.clamped(spacing)
            addRules(from: 2 * s, to: size.height - s, spacing: s, x: 0 ... size.width)
        case let .dotted(spacing):
            let s = Self.clamped(spacing)
            let r = Self.dotRadius
            for y in stride(from: s / 2, to: size.height, by: s) {
                for x in stride(from: s / 2, to: size.width, by: s) {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
            }
        case let .grid(spacing):
            let s = Self.clamped(spacing)
            for x in stride(from: s, to: size.width, by: s) {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            addRules(from: s, to: size.height, spacing: s, x: 0 ... size.width)
        case .cornell:
            let s = Self.cornellSpacing
            let top = 2 * s
            let summary = (size.height * (1 - Self.cornellSummaryFraction)).rounded()
            let cue = (size.width * Self.cornellCueFraction).rounded()
            addRules(from: top, to: summary, spacing: s, x: 0 ... size.width)
            lines.move(to: CGPoint(x: cue, y: top))
            lines.addLine(to: CGPoint(x: cue, y: summary))
            lines.move(to: CGPoint(x: 0, y: summary))
            lines.addLine(to: CGPoint(x: size.width, y: summary))
        }
    }

    /// Horizontal rules at `start, start + spacing, …` while `< end`.
    private func addRules(from start: CGFloat, to end: CGFloat, spacing: CGFloat, x: ClosedRange<CGFloat>) {
        for y in stride(from: start, to: end, by: spacing) {
            lines.move(to: CGPoint(x: x.lowerBound, y: y))
            lines.addLine(to: CGPoint(x: x.upperBound, y: y))
        }
    }

    /// Guards against zero/negative/non-finite spacing from a corrupt file.
    private static func clamped(_ spacing: Float) -> CGFloat {
        spacing.isFinite ? CGFloat(max(spacing, 4)) : 24
    }
}
