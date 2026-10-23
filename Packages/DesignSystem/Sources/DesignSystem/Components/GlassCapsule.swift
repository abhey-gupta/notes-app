import SwiftUI

/// Floating Liquid Glass capsule for editor chrome (mock §02): 52 pt tall, r26, tight horizontal rhythm.
///
/// Put neighbouring capsules in one `GlassChrome` so they blend and morph together.
/// Chain `.glassEffectID(_:in:)` on the capsule to take part in morph transitions.
public struct GlassCapsule<Content: View>: View {
    private let height: CGFloat
    private let leading: CGFloat
    private let trailing: CGFloat
    private let spacing: CGFloat
    private let content: Content

    public init(
        height: CGFloat = Tokens.Size.capsuleHeight,
        leading: CGFloat = Tokens.Spacing.s,
        trailing: CGFloat = Tokens.Spacing.s,
        spacing: CGFloat = Tokens.Spacing.hairline,
        @ViewBuilder content: () -> Content
    ) {
        self.height = height
        self.leading = leading
        self.trailing = trailing
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: spacing) {
            content
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(height: height)
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

/// 1×22 hairline between tool groups.
public struct ChromeSeparator: View {
    private let height: CGFloat

    public init(height: CGFloat = Tokens.Size.separator.height) {
        self.height = height
    }

    public var body: some View {
        Capsule()
            .fill(Tokens.Colors.separator)
            .frame(width: Tokens.Size.separator.width, height: height)
            .padding(.horizontal, Tokens.Spacing.s)
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
