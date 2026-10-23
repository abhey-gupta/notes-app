import SwiftUI

/// Lightweight SwiftUI paper (r4, dotted template, page shadow) for library placeholders, sheets, and previews.
/// The editor draws real pages in Metal; this mirrors its look with the same tokens.
public struct PaperSurface: View {
    private let theme: PaperTheme
    private let showsDots: Bool

    public init(_ theme: PaperTheme, showsDots: Bool = true) {
        self.theme = theme
        self.showsDots = showsDots
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.page, style: .continuous)
        shape
            .fill(theme.paper.color)
            .overlay {
                if showsDots {
                    DotGrid(color: theme.templateLine.color)
                        .clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(theme.pageEdge.color, lineWidth: 0.5))
            .shadow(Tokens.Shadows.pageContact)
            .shadow(theme.pageShadow)
    }
}

/// Dotted template: 24 pt pitch, dots centred in cells.
public struct DotGrid: View {
    private let color: Color
    private let spacing: CGFloat
    private let radius: CGFloat

    public init(color: Color, spacing: CGFloat = Tokens.Size.templateSpacing, radius: CGFloat = Tokens.Size.templateDot) {
        self.color = color
        self.spacing = spacing
        self.radius = radius
    }

    public var body: some View {
        Canvas { context, size in
            var dots = Path()
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// Desk + a sheet of paper behind preview content so glass has something to refract.
struct PreviewDesk<Content: View>: View {
    var paper: PaperTheme?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()
            PaperSurface(paper ?? (scheme == .dark ? .night : .white))
                .frame(width: 520, height: 680)
                .offset(y: 120)
            content
        }
    }
}

#Preview("PaperSurface · themes") {
    HStack(spacing: 32) {
        ForEach(PaperTheme.allCases) { theme in
            PaperSurface(theme).frame(width: 180, height: 254)
        }
    }
    .padding(40)
    .background(Tokens.Colors.desk)
}

#Preview("PaperSurface · dark desk") {
    HStack(spacing: 32) {
        ForEach(PaperTheme.allCases) { theme in
            PaperSurface(theme).frame(width: 180, height: 254)
        }
    }
    .padding(40)
    .background(Tokens.Colors.desk)
    .preferredColorScheme(.dark)
}
