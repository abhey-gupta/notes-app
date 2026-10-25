import SwiftUI

/// Small glass label, e.g. the "3 of 11" page indicator (mock §02).
public struct GlassPill: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    /// "3 of 11".
    public static func pageIndicator(current: Int, total: Int) -> GlassPill {
        GlassPill("\(current) of \(total)")
    }

    public var body: some View {
        Text(text)
            .font(.pill)
            .tracking(0.12)
            .foregroundStyle(Tokens.Colors.pillText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .contentTransition(.numericText())
    }
}

/// Compact chrome while writing (mock §05): current tool, current color, expand.
/// Chain `.glassEffectID(_:in:)` with the tools capsule's ID so collapsing is a morph, not a fade.
/// `axis: .vertical` stacks the same pieces for a side-docked toolbar.
public struct FocusPill: View {
    private let axis: Axis
    private let tool: Symbol
    private let ink: Color
    private let onTool: () -> Void
    private let onExpand: () -> Void

    public init(
        axis: Axis = .horizontal,
        tool: Symbol,
        ink: Color,
        onTool: @escaping () -> Void = {},
        onExpand: @escaping () -> Void
    ) {
        self.axis = axis
        self.tool = tool
        self.ink = ink
        self.onTool = onTool
        self.onExpand = onExpand
    }

    public var body: some View {
        GlassCapsule(
            axis: axis,
            height: Tokens.Size.focusPillHeight,
            leading: Self.endPadding,
            trailing: Self.endPadding,
            spacing: 0
        ) {
            FocusPillContent(axis: axis, tool: tool, ink: ink, onTool: onTool, onExpand: onExpand)
        }
    }

    /// Padding at each end of the pill, along its axis.
    public static let endPadding: CGFloat = 5
}

/// The pill's pieces without the glass, for hosts that keep one capsule and swap its content (the dynamic
/// toolbar resizes a single capsule between expanded and compact instead of swapping views).
public struct FocusPillContent: View {
    private let axis: Axis
    private let tool: Symbol
    private let ink: Color
    private let onTool: () -> Void
    private let onExpand: () -> Void
    /// VoiceOver values: "Pen", "Blue".
    private let toolName: String?
    private let colorName: String?

    public init(
        axis: Axis = .horizontal,
        tool: Symbol,
        ink: Color,
        toolName: String? = nil,
        colorName: String? = nil,
        onTool: @escaping () -> Void = {},
        onExpand: @escaping () -> Void
    ) {
        self.axis = axis
        self.tool = tool
        self.ink = ink
        self.toolName = toolName
        self.colorName = colorName
        self.onTool = onTool
        self.onExpand = onExpand
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        let horizontal = axis == .horizontal
        let scale = typeSize.chromeScale
        let button = Tokens.Size.focusToolButton
        let along: Edge.Set = horizontal ? .horizontal : .vertical
        Group {
            ToolButton(
                tool,
                "Current tool",
                isActive: true,
                ink: ink,
                size: horizontal ? button : CGSize(width: button.height, height: button.width),
                iconSize: 17,
                showsDot: false,
                action: onTool
            )
            .accessibilityValue(toolName ?? "")
            .accessibilityHint("Shows the toolbar")
            ColorSwatch(ink, label: "Current color", isSelected: true, diameter: Tokens.Size.focusSwatch)
                .allowsHitTesting(false)
                .accessibilityValue(colorName ?? "")
                .accessibilityRemoveTraits([.isButton, .isSelected])
                .padding(along, Tokens.Spacing.xs)
            ChromeSeparator(axis: axis, height: 18)
                .padding(along, -Tokens.Spacing.xs)
            Button(action: onExpand) {
                Image(systemName: Symbol.disclosure.name)
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(width: 34 * scale, height: 34 * scale)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show toolbar")
        }
    }
}

#Preview("Pills · light") {
    PillsPreview()
}

#Preview("Pills · dark") {
    PillsPreview()
        .preferredColorScheme(.dark)
}

private struct PillsPreview: View {
    var body: some View {
        PreviewDesk {
            VStack(spacing: 28) {
                GlassPill.pageIndicator(current: 3, total: 11)
                FocusPill(tool: .pen, ink: PaperTheme.night.ink(.blue).color) {}
                FocusPill(axis: .vertical, tool: .highlighter, ink: PaperTheme.white.ink(.red).color) {}
            }
        }
    }
}
