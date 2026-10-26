import DesignSystem
import InkModel
import SwiftUI
import Tools

/// Small ⌄ right after the toolbar's quick colors: opens ``QuickColorsEditor`` (#125).
struct QuickColorsButton: View {
    let tools: ToolState
    let paper: DesignSystem.PaperTheme
    let arrowEdge: Edge

    @State private var isPresented = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let scale = typeSize.chromeScale
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: Symbol.disclosure.name)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Tokens.Colors.chromeHeader)
                .frame(width: 20 * scale, height: 28 * scale)
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Edit quick colors")
        .accessibilityIdentifier("quickColorsButton")
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            QuickColorsEditor(tools: tools, paper: paper)
                .chromePopover(paper)
                .presentationCompactAdaptation(.popover)
                .dynamicTypeSize(...DynamicTypeSize.chromeLimit)
        }
    }
}

/// Quick-colors editor (#125): the current inking tool's palette (pen, or highlighter while it is current).
/// Tap a slot to select it; a preset or the custom picker replaces it; + adds one (five at most), Remove drops
/// it (one stays); drag a slot onto another to reorder. Writes `ToolState`, so the toolbar follows live.
struct QuickColorsEditor: View {
    let tools: ToolState
    let paper: DesignSystem.PaperTheme

    /// Selected slot; clamped to the palette in ``slot``.
    @State private var selected: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let presetSwatch: CGFloat = 26
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)
    /// Drag payload prefix, so text dropped from elsewhere isn't read as a slot.
    private static let dragPrefix = "quickColor:"

    private var colors: [InkColor] {
        tools.currentQuickColors
    }

    private var slot: Int {
        min(selected ?? tools.activeQuickColor ?? 0, colors.count - 1)
    }

    private var presets: [PaletteEntry] {
        tools.paletteTool == .highlighter ? PaletteEntry.highlighterPresets : PaletteEntry.penPresets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tools.paletteTool == .highlighter ? "Highlighter colors" : "Pen colors")
                .padding(.top, -6)
            palette
            divider
            presetGrid
            divider
            footer
        }
        .padding(Tokens.Size.popoverPadding)
        .frame(width: Tokens.Size.popoverWidth * typeSize.chromeScale)
        .animation(Tokens.Motion.selection, value: colors)
        .sensoryFeedback(.selection, trigger: colors)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickColorsEditor")
    }

    // MARK: Palette

    private var palette: some View {
        HStack(spacing: 3) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                ColorSwatch(color.color(on: paper), label: color.label, isSelected: index == slot, diameter: Tokens.Size.paletteSwatch) {
                    selected = index
                }
                .draggable("\(Self.dragPrefix)\(index)") {
                    Circle().fill(color.color(on: paper)).frame(width: Tokens.Size.paletteSwatch, height: Tokens.Size.paletteSwatch)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let source = items.first.flatMap(Self.dragIndex) else { return false }
                    move(from: source, to: index)
                    return true
                }
                .accessibilityValue("Slot \(index + 1) of \(colors.count)")
                .accessibilityAction(named: "Move earlier") { move(from: index, to: index - 1) }
                .accessibilityAction(named: "Move later") { move(from: index, to: index + 1) }
            }
            if colors.count < ToolSettings.quickColorCounts.upperBound {
                addButton
            }
        }
    }

    private var addButton: some View {
        let scale = Tokens.Size.paletteSwatch / Tokens.Size.swatch
        let frame = Tokens.Size.paletteSwatch + 2 * Tokens.Size.swatchRingOuter * scale
        return Button(action: add) {
            Image(systemName: Symbol.add.name)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Tokens.Colors.chromeHeader)
                .frame(width: Tokens.Size.paletteSwatch, height: Tokens.Size.paletteSwatch)
                .overlay(Circle().strokeBorder(Tokens.Colors.chromeHeader, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
                .frame(width: frame, height: frame)
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Add color")
        .accessibilityIdentifier("addQuickColor")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // MARK: Presets

    private var presetGrid: some View {
        let current = colors[slot]
        return LazyVGrid(columns: Self.columns, spacing: 3) {
            ForEach(presets, id: \.self) { entry in
                ColorSwatch(
                    entry.color.color(on: paper),
                    label: entry.name,
                    isSelected: current == entry.color,
                    diameter: Self.presetSwatch
                ) {
                    tools.setQuickColor(entry.color, at: slot)
                }
            }
            CustomColorWell(
                selection: Binding { colors[slot] } set: { tools.setQuickColor($0, at: slot) },
                isSelected: !presets.contains { $0.color == current },
                paper: paper,
                diameter: Self.presetSwatch
            )
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Drag to reorder")
                .scaledFont(size: 13)
                .foregroundStyle(Tokens.Colors.chromeHeader)
            Spacer(minLength: Tokens.Spacing.m)
            Button("Remove", role: .destructive) {
                let index = slot
                tools.removeQuickColor(at: index)
                selected = min(index, colors.count - 1)
            }
            .scaledFont(size: 14, weight: .medium)
            .foregroundStyle(.red)
            .buttonStyle(.plain)
            .disabled(colors.count <= ToolSettings.quickColorCounts.lowerBound)
            .opacity(colors.count <= ToolSettings.quickColorCounts.lowerBound ? 0.35 : 1)
            .accessibilityIdentifier("removeQuickColor")
        }
        .padding(.horizontal, Tokens.Spacing.xs)
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.Colors.separator)
            .frame(height: 0.5)
            .padding(.vertical, 14)
    }

    // MARK: Actions

    /// New slot: the tool's current color if it isn't in the palette yet, else the first unused preset.
    private func add() {
        let ink = tools.currentColor
        let color = colors.contains(ink) ? presets.first { !colors.contains($0.color) }?.color ?? ink : ink
        if let index = tools.addQuickColor(color) {
            selected = index
        }
    }

    /// Moves a slot; the selection stays on the same color.
    private func move(from source: Int, to destination: Int) {
        guard colors.indices.contains(destination) else { return }
        let current = slot
        tools.moveQuickColor(from: source, to: destination)
        if current == source {
            selected = destination
        } else if source < current, current <= destination {
            selected = current - 1
        } else if destination <= current, current < source {
            selected = current + 1
        }
    }

    private static func dragIndex(_ payload: String) -> Int? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return Int(payload.dropFirst(dragPrefix.count))
    }
}
