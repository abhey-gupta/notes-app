import SwiftUI

/// Page template look (§5.3) for SwiftUI surfaces: thumbnails, pickers, placeholder pages.
/// The editor renders templates in Metal; this mirrors them with the same tokens.
public enum PaperPattern: String, CaseIterable, Sendable, Identifiable {
    case blank, lined, dotted, grid, cornell

    public var id: Self {
        self
    }

    public var displayName: String {
        rawValue.capitalized
    }
}

/// Procedural template drawn in one `Canvas` pass. `spacing` is in view points (scale it for thumbnails).
public struct PaperPatternView: View {
    private let pattern: PaperPattern
    private let color: Color
    private let spacing: CGFloat

    public init(_ pattern: PaperPattern, color: Color, spacing: CGFloat = Tokens.Size.templateSpacing) {
        self.pattern = pattern
        self.color = color
        self.spacing = spacing
    }

    public var body: some View {
        switch pattern {
        case .blank:
            Color.clear
        case .dotted:
            DotGrid(color: color, spacing: spacing, radius: max(0.6, Tokens.Size.templateDot * spacing / Tokens.Size.templateSpacing))
        case .lined, .grid, .cornell:
            Canvas { context, size in
                context.stroke(path(in: size), with: .color(color), lineWidth: lineWidth)
            }
            .accessibilityHidden(true)
        }
    }

    private var lineWidth: CGFloat {
        max(0.5, spacing / Tokens.Size.templateSpacing)
    }

    /// Mirrors `InkGeometry.TemplateGeometry` (which DesignSystem can't import) at `spacing / 24` view
    /// points per page point: rules from 72 pt, grid on multiples of the spacing, Cornell 24 pt rules with
    /// a 180 pt cue column and a 144 pt summary band.
    private func path(in size: CGSize) -> Path {
        var path = Path()
        let k = spacing / Tokens.Size.templateSpacing
        let top = 72 * k
        let summary = pattern == .cornell ? max(size.height - 144 * k, top) : size.height
        func rules(from start: CGFloat) {
            var y = start
            while y < summary {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
        }
        switch pattern {
        case .lined, .cornell:
            rules(from: top)
        case .grid:
            rules(from: spacing)
            var x = spacing
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
        default:
            break
        }
        if pattern == .cornell {
            let cue = min(180 * k, size.width / 2)
            path.move(to: CGPoint(x: cue, y: top - spacing))
            path.addLine(to: CGPoint(x: cue, y: summary))
            path.move(to: CGPoint(x: 0, y: summary))
            path.addLine(to: CGPoint(x: size.width, y: summary))
        }
        return path
    }
}

#Preview("PaperPattern") {
    HStack(spacing: 24) {
        ForEach(PaperPattern.allCases) { pattern in
            PaperSurface(.white, pattern: pattern, spacing: 10)
                .frame(width: 72, height: 92)
        }
    }
    .padding(40)
    .background(Tokens.Colors.desk)
}
