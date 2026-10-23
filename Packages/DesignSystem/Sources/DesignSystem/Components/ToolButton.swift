import SwiftUI

/// 44×40 r20 chrome button. Active = interactive glass tinted with the current ink + 4 pt ink dot.
public struct ToolButton: View {
    private let symbol: Symbol
    private let label: String
    private let isActive: Bool
    private let ink: Color?
    private let size: CGSize
    private let iconSize: CGFloat
    private let showsDot: Bool
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - ink: current ink; tints the active glass and fills the dot. Defaults to primary ink.
    ///   - showsDot: the compact focus pill shows the tint only.
    public init(
        _ symbol: Symbol,
        _ label: String,
        isActive: Bool = false,
        ink: Color? = nil,
        size: CGSize = Tokens.Size.toolButton,
        iconSize: CGFloat = Tokens.Size.toolIcon,
        showsDot: Bool = true,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.isActive = isActive
        self.ink = ink
        self.size = size
        self.iconSize = iconSize
        self.showsDot = showsDot
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol.name)
                .font(.system(size: iconSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isActive ? Tokens.Colors.iconActive : Tokens.Colors.icon)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottom) {
                    if isActive, showsDot {
                        Circle()
                            .fill(inkColor)
                            .frame(width: Tokens.Size.activeDot, height: Tokens.Size.activeDot)
                            .padding(.bottom, 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(ToolButtonStyle())
        .glassEffect(glass, in: .capsule)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: isActive)
    }

    private var inkColor: Color {
        ink ?? Tokens.Colors.inkPrimary.color
    }

    private var glass: Glass {
        isActive ? .regular.tint(inkColor.opacity(0.10)).interactive() : .identity
    }
}

/// Press feedback for resting buttons (active ones get interactive glass instead).
private struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule()
                    .fill(Tokens.Colors.iconActive)
                    .opacity(configuration.isPressed ? 0.08 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

#Preview("ToolButton · light") {
    ToolButtonPreview()
}

#Preview("ToolButton · dark") {
    ToolButtonPreview()
        .preferredColorScheme(.dark)
}

private struct ToolButtonPreview: View {
    @State private var tool: Symbol = .pen

    var body: some View {
        PreviewDesk {
            GlassChrome {
                GlassCapsule {
                    ForEach([Symbol.pen, .highlighter, .eraser, .lasso], id: \.self) { symbol in
                        ToolButton(symbol, symbol.rawValue, isActive: tool == symbol, ink: Tokens.Colors.inkBlue.color) {
                            tool = symbol
                        }
                    }
                    ChromeSeparator()
                    ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton) {}
                    ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton) {}
                        .disabled(true)
                }
            }
        }
    }
}
