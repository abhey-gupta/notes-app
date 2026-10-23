import CoreGraphics
import InkModel

/// Page template marks as vector paths in page space (the Metal engine draws these procedurally).
struct TemplatePaths {
    /// Rules and grid lines (stroke).
    var lines: CGPath
    /// Dots (fill).
    var dots: CGPath

    /// Hairline width (pt) for ``lines``.
    static let lineWidth: CGFloat = 0.75
    /// Dot radius (pt).
    static let dotRadius: CGFloat = 1

    init(_ template: PageTemplate, size: CGSize) {
        let lines = CGMutablePath()
        let dots = CGMutablePath()
        let top: CGFloat = 72
        func rules(spacing: CGFloat, from x0: CGFloat = 0, to x1: CGFloat, until bottom: CGFloat) {
            var y = top
            while y < bottom {
                lines.move(to: CGPoint(x: x0, y: y))
                lines.addLine(to: CGPoint(x: x1, y: y))
                y += spacing
            }
        }
        switch template {
        case .blank:
            break
        case let .lined(spacing):
            rules(spacing: max(CGFloat(spacing), 4), to: size.width, until: size.height)
        case let .dotted(spacing):
            Self.addDots(to: dots, spacing: max(CGFloat(spacing), 4), size: size)
        case let .grid(spacing):
            Self.addGrid(to: lines, spacing: max(CGFloat(spacing), 4), size: size)
        case .cornell:
            // Cue column (29 % width) and summary band (bottom 18 %) over 24 pt rules.
            let summary = (size.height * 0.82).rounded()
            let cue = (size.width * 0.29).rounded()
            rules(spacing: 24, to: size.width, until: summary)
            lines.move(to: CGPoint(x: cue, y: top - 24))
            lines.addLine(to: CGPoint(x: cue, y: summary))
            lines.move(to: CGPoint(x: 0, y: summary))
            lines.addLine(to: CGPoint(x: size.width, y: summary))
        }
        self.lines = lines
        self.dots = dots
    }

    private static func addDots(to path: CGMutablePath, spacing s: CGFloat, size: CGSize) {
        let r = dotRadius
        var y = s
        while y < size.height {
            var x = s
            while x < size.width {
                path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                x += s
            }
            y += s
        }
    }

    private static func addGrid(to path: CGMutablePath, spacing s: CGFloat, size: CGSize) {
        var x = s
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += s
        }
        var y = s
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += s
        }
    }

    /// Draws paper and template into `context` (page space).
    static func drawBackground(_ template: PageTemplate, size: CGSize, paper: CGColor, line: CGColor, in context: CGContext) {
        context.setFillColor(paper)
        context.fill(CGRect(origin: .zero, size: size))
        let paths = TemplatePaths(template, size: size)
        context.setStrokeColor(line)
        context.setLineWidth(lineWidth)
        context.addPath(paths.lines)
        context.strokePath()
        context.setFillColor(line)
        context.addPath(paths.dots)
        context.fillPath()
    }
}

extension RGBA8 {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
