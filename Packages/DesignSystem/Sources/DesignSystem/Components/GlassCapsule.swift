import SwiftUI

/// Floating Liquid Glass capsule for editor chrome (mock §02): 52 pt thick, r26, tight rhythm along `axis`.
///
/// Put neighbouring capsules in one `GlassChrome` so they blend and morph together.
/// Chain `.glassEffectID(_:in:)` on the capsule to take part in morph transitions. Changing `axis` re-flows
/// the same children through one `AnyLayout`, so a dock change animates instead of swapping views.
public struct GlassCapsule<Content: View>: View {
    private let axis: Axis
    private let height: CGFloat
    private let leading: CGFloat
    private let trailing: CGFloat
    private let spacing: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - height: thickness across `axis` (the width of a vertical capsule).
    ///   - leading, trailing: end padding along `axis` (top and bottom when vertical).
    public init(
        axis: Axis = .horizontal,
        height: CGFloat = Tokens.Size.capsuleHeight,
        leading: CGFloat = Tokens.Spacing.s,
        trailing: CGFloat = Tokens.Spacing.s,
        spacing: CGFloat = Tokens.Spacing.hairline,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.height = height
        self.leading = leading
        self.trailing = trailing
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        let horizontal = axis == .horizontal
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
        layout {
            content
        }
        .padding(
            horizontal
                ? EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
                : EdgeInsets(top: leading, leading: 0, bottom: trailing, trailing: 0)
        )
        .frame(width: horizontal ? nil : height, height: horizontal ? height : nil)
        // Keeps content inside the glass while the capsule resizes (expanded ⇄ compact, axis re-flow).
        .clipShape(.capsule)
        .glassEffect(.regular, in: .capsule)
    }
}

/// One `GlassEffectContainer` for all editor capsules (§7): shared sampling, blending, and morphs.
public struct GlassChrome<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = Tokens.Spacing.glassBlend, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

/// 1×22 hairline between tool groups, drawn across `axis` (a horizontal rule in a vertical capsule).
public struct ChromeSeparator: View {
    private let axis: Axis
    private let height: CGFloat

    /// - Parameter height: length across the capsule.
    public init(axis: Axis = .horizontal, height: CGFloat = Tokens.Size.separator.height) {
        self.axis = axis
        self.height = height
    }

    public var body: some View {
        let horizontal = axis == .horizontal
        let thin = Tokens.Size.separator.width
        let gap = Tokens.Spacing.s
        Capsule()
            .fill(Tokens.Colors.separator)
            .frame(width: horizontal ? thin : height, height: horizontal ? height : thin)
            .padding(
                horizontal
                    ? EdgeInsets(top: 0, leading: gap, bottom: 0, trailing: gap)
                    : EdgeInsets(top: gap, leading: 0, bottom: gap, trailing: 0)
            )
            .accessibilityHidden(true)
    }
}

#Preview("GlassCapsule · light") {
    GlassCapsulePreview()
}

#Preview("GlassCapsule · dark") {
    GlassCapsulePreview()
        .preferredColorScheme(.dark)
}

private struct GlassCapsulePreview: View {
    var body: some View {
        PreviewDesk {
            GlassChrome {
                HStack(spacing: 40) {
                    GlassCapsule(leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.l) {
                        ToolButton(.back, "Back") {}
                        Text("Thermodynamics").font(.chromeTitle)
                    }
                    GlassCapsule {
                        ToolButton(.pages, "Pages") {}
                        ToolButton(.share, "Share") {}
                        ToolButton(.more, "More") {}
                    }
                }
            }
        }
    }
}
