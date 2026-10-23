import SwiftUI
import UIKit

/// Physical notebook cover (mock §01): cloth color, sheen, fine weave, spine crease, paper label.
/// Geometry is authored at 150×196 and scales with `width`.
public struct NotebookCover: View {
    private let title: String
    private let caption: String?
    private let color: CoverColor
    private let width: CGFloat

    public init(title: String, caption: String? = nil, color: CoverColor, width: CGFloat = Tokens.Size.cover.width) {
        self.title = title
        self.caption = caption
        self.color = color
        self.width = width
    }

    private var scale: CGFloat {
        width / Tokens.Size.cover.width
    }

    /// Label inset 28/16 from the cover edges, 9 pt padding inside.
    private var labelTextWidth: CGFloat {
        (Tokens.Size.cover.width - 28 - 16 - 18) * scale
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Tokens.Radius.coverSpine * scale,
            bottomLeadingRadius: Tokens.Radius.coverSpine * scale,
            bottomTrailingRadius: Tokens.Radius.coverEdge * scale,
            topTrailingRadius: Tokens.Radius.coverEdge * scale,
            style: .continuous
        )
    }

    public var body: some View {
        shape
            .fill(color.color)
            .overlay { CoverWeave().clipShape(shape) }
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .black.opacity(0.08)],
                        startPoint: UnitPoint(x: 0.33, y: 0),
                        endPoint: UnitPoint(x: 0.67, y: 1)
                    )
                )
            }
            .overlay(alignment: .leading) { spine }
            .overlay(alignment: .topLeading) { label }
            .frame(width: width, height: width * Tokens.Size.cover.height / Tokens.Size.cover.width)
            .compositingGroup()
            .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
            .shadow(Tokens.Shadows.cover)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    private var spine: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.18)).frame(width: 1)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1)
        }
        .padding(.leading, 10 * scale)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text(Self.labelText(title, width: labelTextWidth, font: Typography.uiFont(size: 15 * scale)))
                .font(.notebookTitle(size: 15 * scale))
                .foregroundStyle(CoverColor.labelText.color)
                .lineLimit(3)
                .lineSpacing(-2)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 9 * scale, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(0.72 * scale)
                    .foregroundStyle(CoverColor.labelCaption.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9 * scale)
        .padding(.top, 7 * scale)
        .padding(.bottom, 8 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CoverColor.label.color, in: .rect(cornerRadius: 3 * scale))
        .padding(.leading, 28 * scale)
        .padding(.trailing, 16 * scale)
        .padding(.top, 30 * scale)
    }
}

extension NotebookCover {
    /// Words wider than the label get a hard "-" break at the hyphenation point nearest their middle, so
    /// "Thermodynamics" reads "Thermo-/dynamics" like the mock instead of orphaning letters.
    /// (Soft hyphens alone let TextKit pick the last-fitting point, e.g. "Thermodynam-/ics".)
    static func labelText(_ title: String, width: CGFloat, font: UIFont, locale: Locale = .current) -> String {
        let cfLocale = locale as CFLocale
        let canHyphenate = CFStringIsHyphenationAvailableForLocale(cfLocale)
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let word = String(word)
            guard word.count >= 6, (word as NSString).size(withAttributes: [.font: font]).width > width else { return word }
            let ns = word as NSString
            let range = CFRange(location: 0, length: ns.length)
            var candidates = Set<Int>()
            if canHyphenate {
                for index in 3 ..< (ns.length - 2) {
                    let hyphen = CFStringGetHyphenationLocationBeforeIndex(ns as CFString, index, range, 0, cfLocale, nil)
                    if hyphen != kCFNotFound, hyphen >= 3 {
                        candidates.insert(hyphen)
                    }
                }
            }
            let middle = ns.length / 2
            let split = candidates.min { (abs($0 - middle), $0) < (abs($1 - middle), $1) } ?? middle
            return ns.substring(to: split) + "-\n" + ns.substring(from: split)
        }
        return words.joined(separator: " ")
    }
}

/// Fine 45° weave (`repeating-linear-gradient(45deg, white .035 0 2px, transparent 2px 4px)`).
private struct CoverWeave: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var offset: CGFloat = -size.height
            while offset < size.width {
                lines.move(to: CGPoint(x: offset, y: size.height))
                lines.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += 4
            }
            context.stroke(lines, with: .color(.white.opacity(0.035)), lineWidth: 1.4)
        }
        .accessibilityHidden(true)
    }
}

#Preview("NotebookCover · light") {
    CoverPreview()
}

#Preview("NotebookCover · dark") {
    CoverPreview()
        .preferredColorScheme(.dark)
}

private struct CoverPreview: View {
    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 39) {
                ForEach(CoverColor.allCases.prefix(4)) { cover in
                    NotebookCover(title: "Thermodynamics", caption: "Physics II", color: cover)
                }
            }
            NotebookCover(title: "Organic Chemistry", caption: "Semester 3", color: .navy, width: 180)
                .rotationEffect(.degrees(-3))
        }
        .padding(40)
        .background(Tokens.Colors.libraryBackground)
    }
}
