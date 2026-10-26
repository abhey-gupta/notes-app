import DesignSystem
import InkModel
import SwiftUI
import Tools

/// Lasso context bar (§6): a Liquid Glass capsule over the selection with the quick colors, the full
/// palette, duplicate and delete. Hidden while the selection is dragged. Each button is one undo step.
///
/// Positioned in screen space from ``EditorState/selectionFrame`` (the canvas fills the screen): centered
/// above the selection, or below it when there's no room under the top chrome.
struct SelectionBar: View {
    let tools: ToolState
    let state: EditorState
    let paper: DesignSystem.PaperTheme

    @State private var size = CGSize(width: 300, height: Tokens.Size.capsuleHeight)
    @State private var showsPalette = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Gap between selection and bar, and the space the top chrome needs.
    private static let gap: CGFloat = 14
    private static let topClearance: CGFloat = 132

    var body: some View {
        GeometryReader { proxy in
            if let frame = state.selectionFrame {
                bar
                    .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                    .position(position(for: frame, in: proxy.size))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.2), value: state.selectionFrame == nil)
        .onChange(of: state.selectionFrame == nil) { _, hidden in
            if hidden {
                showsPalette = false
            }
        }
    }

    private var bar: some View {
        GlassCapsule {
            ForEach(Array(tools.quickColors.enumerated()), id: \.offset) { _, color in
                ColorSwatch(color.color(on: paper), label: color.label) {
                    state.perform(.recolor(color))
                }
            }
            ToolButton(.palette, "Colors", size: Tokens.Size.compactToolButton) {
                showsPalette.toggle()
            }
            .popover(isPresented: $showsPalette) {
                palette
            }
            ChromeSeparator()
            ToolButton(.duplicate, "Duplicate", size: Tokens.Size.compactToolButton) {
                state.perform(.duplicate)
            }
            ToolButton(.delete, "Delete", size: Tokens.Size.compactToolButton) {
                state.perform(.delete)
            }
        }
        .fixedSize()
        .chromeAppearance(paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selectionBar")
    }

    private var palette: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed((Tokens.Size.paletteSwatch + 8) * typeSize.chromeScale), spacing: 6), count: 6),
            spacing: 8
        ) {
            ForEach(Array(Tokens.palette.enumerated()), id: \.offset) { _, rgba in
                ColorSwatch(rgba.color, label: InkColor(palette: rgba).accessibilityName, diameter: Tokens.Size.paletteSwatch) {
                    showsPalette = false
                    state.perform(.recolor(InkColor(palette: rgba)))
                }
            }
        }
        .padding(Tokens.Spacing.l)
        .chromePopover(paper)
        .presentationCompactAdaptation(.popover)
    }

    private func position(for frame: CGRect, in container: CGSize) -> CGPoint {
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let margin: CGFloat = 12
        let x = min(max(frame.midX, half.width + margin), max(container.width - half.width - margin, half.width + margin))
        let above = frame.minY - Self.gap - half.height
        let y = above - half.height >= Self.topClearance ? above : frame.maxY + Self.gap + half.height
        return CGPoint(x: x, y: min(max(y, Self.topClearance + half.height), container.height - half.height - margin))
    }
}

extension InkColor {
    /// A palette color as ink: the semantic slot when it is one (so it follows Night remapping), else custom.
    init(palette rgba: RGBA) {
        let slots: [SemanticInk] = [.primary, .blue, .red, .accent]
        if let slot = slots.first(where: { DesignSystem.PaperTheme.white.ink($0.role) == rgba }) {
            self = .semantic(slot)
        } else {
            self = .custom(RGBA8(rgba))
        }
    }
}
