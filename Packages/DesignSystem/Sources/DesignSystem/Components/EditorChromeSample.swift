import SwiftUI

/// Reference composition of the editor chrome (mock §02 → §05): three capsules in one `GlassChrome`,
/// collapsing into `FocusPill` via a `glassEffectID` morph. The real `ToolbarHost` (§7) reuses these pieces.
public struct EditorChromeSample: View {
    @Binding private var isFocused: Bool
    private let title: String
    private let paper: PaperTheme

    @State private var tool: Symbol = .pen
    @State private var quickColor = 0
    @Namespace private var glass

    private enum ChromeID: Hashable {
        case nav, tools, pages
    }

    private static let tools: [(Symbol, String)] = [
        (.pen, "Pen"), (.highlighter, "Highlighter"), (.eraser, "Eraser"), (.lasso, "Lasso"), (.laser, "Laser"),
    ]

    public init(isFocused: Binding<Bool>, title: String, paper: PaperTheme) {
        _isFocused = isFocused
        self.title = title
        self.paper = paper
    }

    public var body: some View {
        GlassChrome {
            ZStack(alignment: .top) {
                if isFocused {
                    FocusPill(tool: tool, ink: ink) {
                        setFocused(false)
                    }
                    .glassEffectID(ChromeID.tools, in: glass)
                } else {
                    navCapsule
                        .glassEffectID(ChromeID.nav, in: glass)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    toolsCapsule
                        .glassEffectID(ChromeID.tools, in: glass)
                    pagesCapsule
                        .glassEffectID(ChromeID.pages, in: glass)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Tokens.Spacing.chromeInset)
    }

    private var ink: Color {
        paper.ink(Tokens.quickColors[quickColor]).color
    }

    private func setFocused(_ focused: Bool) {
        withAnimation(Tokens.Motion.morph) {
            isFocused = focused
        }
    }

    private var navCapsule: some View {
        GlassCapsule(leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.l, spacing: 0) {
            ToolButton(.back, "Library") {}
            Text(title)
                .font(.chromeTitle)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
            Image(systemName: Symbol.disclosure.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.Colors.textTertiary)
                .padding(.leading, 6)
                .accessibilityHidden(true)
        }
    }

    private var toolsCapsule: some View {
        GlassCapsule {
            ForEach(Self.tools, id: \.0) { symbol, label in
                ToolButton(symbol, label, isActive: tool == symbol, ink: ink) {
                    tool = symbol
                }
            }
            ChromeSeparator()
            ForEach(Array(Tokens.quickColors.enumerated()), id: \.offset) { index, role in
                ColorSwatch(paper.ink(role).color, label: role.rawValue.capitalized, isSelected: quickColor == index) {
                    quickColor = index
                }
            }
            ChromeSeparator()
            ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton) {}
            ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton) {}
                .disabled(true)
        }
    }

    private var pagesCapsule: some View {
        GlassCapsule {
            ToolButton(.pages, "Pages") {}
            ToolButton(.share, "Share") {}
            ToolButton(.more, "More") { // demo: enters focus mode
                setFocused(true)
            }
        }
    }
}

#Preview("EditorChrome · light") {
    EditorChromePreview(paper: .white)
}

#Preview("EditorChrome · dark") {
    EditorChromePreview(paper: .night)
        .preferredColorScheme(.dark)
}

private struct EditorChromePreview: View {
    let paper: PaperTheme
    @State private var focused = false

    var body: some View {
        PreviewDesk(paper: paper) {
            VStack {
                EditorChromeSample(isFocused: $focused, title: "Thermodynamics", paper: paper)
                Spacer()
                HStack {
                    Spacer()
                    GlassPill.pageIndicator(current: 3, total: 11)
                }
                .padding(Tokens.Spacing.chromeInset)
            }
            .padding(.top, 8)
        }
    }
}
