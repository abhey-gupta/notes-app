import DesignSystem
import InkModel
import SwiftUI
import Tools

// MARK: - Controls

/// Mock §03 segmented control: a sliding raised segment on a subtle track.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Namespace private var namespace

    init(_ options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.options = options
        _selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Tokens.Motion.selection) { selection = option }
                } label: {
                    Text(title(option))
                        .scaledFont(size: 13, weight: selected ? .semibold : .medium)
                        .foregroundStyle(selected ? Tokens.Colors.chromeText : Tokens.Colors.chromeTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Tokens.Radius.segment, style: .continuous)
                                    .fill(Tokens.Colors.field)
                                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Tokens.Colors.subtleFill, in: .rect(cornerRadius: Tokens.Radius.segmented, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Evenly spaced width / size options; the selection highlight slides between them.
struct OptionRow<Glyph: View>: View {
    /// Option values, spoken after `label` ("Width 2.5").
    let values: [Float]
    @Binding var selection: Int
    /// VoiceOver label prefix ("Width" → "Width 1.5"…).
    let label: String
    @ViewBuilder let glyph: (Int, Bool) -> Glyph
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                let selected = index == selection
                if index > 0 {
                    Spacer(minLength: 0)
                }
                Button {
                    withAnimation(Tokens.Motion.selection) { selection = index }
                } label: {
                    glyph(index, selected)
                        .scaleEffect(selected ? 1.08 : 1)
                        .frame(width: Tokens.Size.widthOption, height: Tokens.Size.widthOption)
                        .background {
                            if selected {
                                Circle()
                                    .fill(Tokens.Colors.chromeSelected)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("\(label) \(values[index].formatted())")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Palette swatches (6 per row) and a custom color well.
struct PaletteGrid: View {
    let colors: [PaletteEntry]
    @Binding var selection: InkColor
    let paper: DesignSystem.PaperTheme

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)

    var body: some View {
        // Swatch frames include the ring; 3 pt between frames is the mock's 12 pt between circles.
        LazyVGrid(columns: Self.columns, spacing: 3) {
            ForEach(colors, id: \.self) { entry in
                ColorSwatch(
                    entry.color.color(on: paper),
                    label: entry.name,
                    isSelected: selection == entry.color,
                    diameter: Tokens.Size.paletteSwatch
                ) {
                    withAnimation(Tokens.Motion.selection) { selection = entry.color }
                }
            }
            CustomColorWell(selection: $selection, isSelected: !colors.contains { $0.color == selection }, paper: paper)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// System color picker in the palette's last cell; ringed when the current color isn't a palette color.
struct CustomColorWell: View {
    @Binding var selection: InkColor
    let isSelected: Bool
    let paper: DesignSystem.PaperTheme
    var diameter = Tokens.Size.paletteSwatch

    var body: some View {
        let scale = diameter / Tokens.Size.swatch
        let frame = diameter + 2 * Tokens.Size.swatchRingOuter * scale
        ColorPicker("Custom color", selection: color, supportsOpacity: false)
            .labelsHidden()
            .frame(width: frame, height: frame)
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(
                            selection.color(on: paper),
                            lineWidth: (Tokens.Size.swatchRingOuter - Tokens.Size.swatchRingGap) * scale
                        )
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: isSelected)
            .accessibilityIdentifier("customColor")
    }

    private var color: Binding<Color> {
        Binding {
            selection.color(on: paper)
        } set: { picked in
            selection = InkColor.picked(RGBA8(UIColor(picked)))
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .scaledFont(size: 11.5, weight: .semibold)
            .textCase(.uppercase)
            .tracking(11.5 * 0.06)
            .foregroundStyle(Tokens.Colors.chromeHeader)
            .padding(.horizontal, Tokens.Spacing.hairline)
            .padding(.top, 14)
            .padding(.bottom, Tokens.Spacing.m)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Palette

/// A palette color and its VoiceOver name.
struct PaletteEntry: Hashable {
    let color: InkColor
    let name: String

    /// The 11 pen colors (`Tokens.palette`). Entries equal to a semantic ink's light value are that slot, so
    /// they adapt on Night like the default quick colors.
    static let pen: [PaletteEntry] = zip(Tokens.palette, [
        "Black", "Graphite", "Blue", "Green", "Red", "Orange", "Purple", "Pink", "Teal", "Brown", "Yellow",
    ]).map { PaletteEntry(color: .palette($0), name: $1) }

    /// Highlighter colors (`Tokens.highlighterPalette`).
    static let highlighter: [PaletteEntry] = zip(Tokens.highlighterPalette, [
        "Yellow", "Orange", "Pink", "Purple", "Teal", "Green",
    ]).map { PaletteEntry(color: .custom(RGBA8($0)), name: $1) }

    /// Quick-colors editor presets (#125): the pen colors plus `Tokens.penPresetExtras`.
    static let penPresets: [PaletteEntry] = pen + zip(Tokens.penPresetExtras, [
        "Navy", "Sage", "Dusty blue", "Rose",
    ]).map { PaletteEntry(color: .custom(RGBA8($0)), name: $1) }

    /// Highlighter presets: the highlighter colors plus `Tokens.highlighterPresetExtras`.
    static let highlighterPresets: [PaletteEntry] = highlighter + zip(Tokens.highlighterPresetExtras, [
        "Lime", "Mint", "Sky", "Blue", "Lavender", "Rose", "Coral", "Peach", "Gray",
    ]).map { PaletteEntry(color: .custom(RGBA8($0)), name: $1) }
}

extension InkColor {
    /// A palette value: the semantic slot whose light value it is, else custom.
    static func palette(_ rgba: RGBA) -> InkColor {
        let value = RGBA8(rgba)
        return InkRole.allCases.first { RGBA8(DesignSystem.PaperTheme.white.ink($0)) == value }.map { .semantic($0.semantic) }
            ?? .custom(value)
    }

    /// A color from the system picker, opaque: a pen palette entry if it is one, custom otherwise.
    static func picked(_ rgba: RGBA8) -> InkColor {
        var opaque = rgba
        opaque.a = 255
        return PaletteEntry.pen.first { $0.color.lightValue == opaque }?.color ?? .custom(opaque)
    }

    /// Light-paper value.
    private var lightValue: RGBA8 {
        switch self {
        case let .semantic(slot): RGBA8(DesignSystem.PaperTheme.white.ink(slot.role))
        case let .custom(rgba): rgba
        }
    }
}

extension PenKind {
    var displayName: String {
        switch self {
        case .fountain: "Fountain"
        case .ballpoint: "Ballpoint"
        case .brush: "Brush"
        case .highlighter: "Highlighter"
        }
    }
}

extension EraserSettings.Mode {
    var displayName: String {
        switch self {
        case .stroke: "Stroke"
        case .partial: "Partial"
        }
    }

    var caption: String {
        switch self {
        case .stroke: "Removes whole strokes it touches."
        case .partial: "Erases only where it passes."
        }
    }
}
