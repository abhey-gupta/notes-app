import DesignSystem
import InkModel
import SwiftUI
import Tools

/// Quick-color editor (#125), from the ⌄ after the toolbar's swatches. Edits the palette the toolbar shows:
/// the highlighter's while it's current, else the pen's.
///
/// Tap a slot to select it (ring), dashed + adds one (up to five). A preset or the custom well replaces the
/// selected slot. Drag slots to reorder; Remove drops the selected one (never the last).
struct QuickColorsPopover: View {
    let tools: ToolState
    let paper: DesignSystem.PaperTheme

    @State private var selected: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    init(tools: ToolState, paper: DesignSystem.PaperTheme) {
        self.tools = tools
        self.paper = paper
        _selected = State(initialValue: tools.activeQuickColor ?? 0)
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)
    private static let presetDiameter: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(isHighlighter ? "Highlighter colors" : "Pen colors")
                .padding(.top, -Tokens.Spacing.xs)
            slots
            Divider().padding(.vertical, Tokens.Spacing.l)
            LazyVGrid(columns: Self.columns, spacing: Tokens.Spacing.s) {
                ForEach(presets, id: \.self) { entry in
                    ColorSwatch(
                        entry.color.color(on: paper),
                        label: entry.name,
                        isSelected: selectedColor == entry.color,
                        diameter: Self.presetDiameter
                    ) {
                        replace(with: entry.color)
                    }
                }
                CustomColorWell(selection: customBinding, isSelected: !presets.contains { $0.color == selectedColor }, paper: paper)
                    .scaleEffect(Self.presetDiameter / Tokens.Size.paletteSwatch)
            }
            .sensoryFeedback(.selection, trigger: selectedColor)
            Divider().padding(.vertical, Tokens.Spacing.l)
            HStack {
                Text("Drag to reorder")
                    .scaledFont(size: 13)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                Spacer()
                Button("Remove", role: .destructive, action: remove)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .disabled(palette.count <= 1)
                    .opacity(palette.count <= 1 ? 0.35 : 1)
                    .accessibilityIdentifier("removeQuickColor")
            }
        }
        .padding(Tokens.Size.popoverPadding)
        .frame(width: Tokens.Size.popoverWidth * typeSize.chromeScale)
        .chromePopover(for: paper)
        .animation(Tokens.Motion.selection, value: palette)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickColorsPopover")
    }

    // MARK: Slots

    private var slots: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ForEach(Array(palette.enumerated()), id: \.offset) { index, color in
                ColorSwatch(
                    color.color(on: paper),
                    label: "Slot \(index + 1), \(color.label)",
                    isSelected: selected == index,
                    diameter: Tokens.Size.paletteSwatch
                ) {
                    selected = index
                }
                .draggable(String(index))
                .dropDestination(for: String.self) { items, _ in
                    guard let source = items.first.flatMap(Int.init) else { return false }
                    move(from: source, to: index)
                    return true
                }
                .accessibilityIdentifier("quickColorSlot-\(index)")
                .accessibilityActions {
                    if index > 0 {
                        Button("Move earlier") { move(from: index, to: index - 1) }
                    }
                    if index < palette.count - 1 {
                        Button("Move later") { move(from: index, to: index + 1) }
                    }
                }
            }
            if palette.count < ToolSettings.maxQuickColors {
                Button(action: add) {
                    Image(systemName: Symbol.add.name)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                        .frame(width: Tokens.Size.paletteSwatch, height: Tokens.Size.paletteSwatch)
                        .overlay(Circle().strokeBorder(Tokens.Colors.textTertiary, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
                        .padding(Tokens.Size.swatchRingOuter * Tokens.Size.paletteSwatch / Tokens.Size.swatch)
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Add color")
                .accessibilityIdentifier("addQuickColor")
            }
        }
    }

    // MARK: Model

    private var isHighlighter: Bool {
        tools.paletteTool == .highlighter
    }

    private var palette: [InkColor] {
        tools.palette
    }

    private var presets: [PaletteEntry] {
        isHighlighter ? PaletteEntry.highlighterPresets : PaletteEntry.penPresets
    }

    private var selectedColor: InkColor? {
        palette.indices.contains(selected) ? palette[selected] : nil
    }

    private var customBinding: Binding<InkColor> {
        Binding { selectedColor ?? tools.paletteColor } set: { replace(with: $0) }
    }

    private func replace(with color: InkColor) {
        tools.setQuickColor(color, at: selected)
    }

    /// A new slot takes the first preset not in the palette yet, and is selected.
    private func add() {
        let color = presets.first { !palette.contains($0.color) }?.color ?? tools.paletteColor
        if let index = tools.addQuickColor(color) {
            selected = index
        }
    }

    private func remove() {
        tools.removeQuickColor(at: selected)
        selected = min(selected, palette.count - 1)
    }

    private func move(from source: Int, to destination: Int) {
        guard source != destination else { return }
        let wasSelected = selected == source
        tools.moveQuickColor(from: source, to: destination)
        if wasSelected {
            selected = destination
        } else if source < selected, destination >= selected {
            selected -= 1
        } else if source > selected, destination <= selected {
            selected += 1
        }
    }
}

extension PaletteEntry {
    /// Pen presets (#125): the 11 pen colors and four quiet extras; 15 + the custom well fill 2×8.
    static let penPresets: [PaletteEntry] = pen + zip(
        [RGBA(0x4A6378), RGBA(0x6E8B6B), RGBA(0xB5677A), RGBA(0x5E3A6E)],
        ["Slate", "Sage", "Rose", "Plum"]
    ).map { PaletteEntry(color: .palette($0), name: $1) }

    /// Highlighter presets: the six highlighter colors and nine soft extras.
    static let highlighterPresets: [PaletteEntry] = highlighter + zip(
        [
            RGBA(0x9BE3B5), RGBA(0x8CCBF2), RGBA(0xC7B3F5), RGBA(0xFFB38A), RGBA(0xFF9EB5),
            RGBA(0xD6F07A), RGBA(0x7FE0D8), RGBA(0xFF8A80), RGBA(0xF2D49B),
        ],
        ["Mint", "Sky", "Lavender", "Peach", "Rose", "Lime", "Aqua", "Coral", "Sand"]
    ).map { PaletteEntry(color: .custom(RGBA8($0)), name: $1) }
}
