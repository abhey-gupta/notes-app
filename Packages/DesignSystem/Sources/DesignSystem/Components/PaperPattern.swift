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

    private func path(in size: CGSize) -> Path {
        var path = Path()
        let top = pattern == .cornell ? spacing * 3 : spacing * (pattern == .lined ? 2.5 : 0.5)
        let bottom = pattern == .cornell ? size.height * 0.8 : size.height
        var y = top
        while y < bottom {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        switch pattern {
        case .grid:
            var x = spacing / 2
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
        case .cornell:
            let cue = size.width * 0.28
            path.move(to: CGPoint(x: cue, y: spacing * 2))
            path.addLine(to: CGPoint(x: cue, y: bottom))
            path.move(to: CGPoint(x: 0, y: bottom))
            path.addLine(to: CGPoint(x: size.width, y: bottom))
        default:
            break
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
