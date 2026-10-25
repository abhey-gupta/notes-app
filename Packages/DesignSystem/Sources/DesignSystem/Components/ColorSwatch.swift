import SwiftUI

/// Ink swatch: 22 pt dot with hairline; selected = clear 2 pt gap + 1.5 pt ring in the swatch color.
/// Ring geometry scales with `diameter` (30 pt palette swatches get a 2.7/4.8 ring).
public struct ColorSwatch: View {
    private let color: Color
    private let label: String
    private let isSelected: Bool
    private let baseDiameter: CGFloat
    private let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        _ color: Color,
        label: String,
        isSelected: Bool = false,
        diameter: CGFloat = Tokens.Size.swatch,
        action: @escaping () -> Void = {}
    ) {
        self.color = color
        self.label = label
        self.isSelected = isSelected
        baseDiameter = diameter
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(Tokens.Colors.swatchHairline, lineWidth: 0.5))
                    .frame(width: diameter, height: diameter)
                if isSelected {
                    Circle()
                        .strokeBorder(color, lineWidth: ringOuter - ringGap)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(width: diameter + 2 * ringOuter, height: diameter + 2 * ringOuter)
            .contentShape(.circle)
        }
        .buttonStyle(SwatchButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: isSelected)
    }

    /// Grows with Dynamic Type (``DynamicTypeSize/chromeScale``).
    private var diameter: CGFloat {
        baseDiameter * typeSize.chromeScale
    }

    private var scale: CGFloat {
        diameter / Tokens.Size.swatch
    }

    private var ringGap: CGFloat {
        Tokens.Size.swatchRingGap * scale
    }

    private var ringOuter: CGFloat {
        Tokens.Size.swatchRingOuter * scale
    }
}

private struct SwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

#Preview("ColorSwatch · light") {
    ColorSwatchPreview()
}

#Preview("ColorSwatch · dark") {
    ColorSwatchPreview()
        .preferredColorScheme(.dark)
}

private struct ColorSwatchPreview: View {
    @State private var selected = 0

    var body: some View {
        PreviewDesk {
            VStack(spacing: 24) {
                GlassCapsule {
                    ForEach(Array(Tokens.quickColors.enumerated()), id: \.offset) { index, role in
                        ColorSwatch(PaperTheme.white.ink(role).color, label: role.rawValue, isSelected: selected == index) {
                            selected = index
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(Tokens.palette.enumerated()), id: \.offset) { index, rgba in
                        ColorSwatch(rgba.color, label: "Color \(index + 1)", isSelected: index == 0, diameter: Tokens.Size.paletteSwatch)
                    }
                }
            }
        }
    }
}
