import SwiftUI

/// Editor chrome look, from the notebook's paper (#122): frosted warm glass + dark ink text on White/Cream,
/// clear glass + light text on Night. Same shapes either way; only material and colors change.
///
/// Set once with ``SwiftUI/View/chromeAppearance(_:)``: it also pins the color scheme, so the `Tokens.Colors.chrome*`
/// pairs resolve to the paper's side whatever the system appearance.
public enum ChromeAppearance: Sendable {
    case frosted, clear

    public init(_ paper: PaperTheme) {
        self = paper.isDark ? .clear : .frosted
    }

    public var colorScheme: ColorScheme {
        self == .clear ? .dark : .light
    }

    /// Capsule material: warm tinted glass, or clear glass smoked with Night paper.
    public var glass: Glass {
        self == .clear ? .clear.tint(Tokens.Colors.chromeSmoke.color) : .regular.tint(Tokens.Colors.chromeFrost.color)
    }

    /// Glass card backing (#126): Night's clear glass needs smoke under text; frosted glass has its own fill.
    public var cardBacking: Color {
        self == .clear ? Tokens.Colors.chromeCardSmoke.color : .clear
    }

    /// Popover background behind the system glass.
    public var popoverBackground: Color {
        (self == .clear ? Tokens.Colors.chromeSmoke : Tokens.Colors.chromeFrost).color
    }
}

public extension EnvironmentValues {
    /// `nil` outside the editor: plain system glass (library, previews).
    @Entry var chromeAppearance: ChromeAppearance?
}

public extension View {
    /// Editor chrome for `paper`: glass material and text colors (#122).
    func chromeAppearance(_ paper: PaperTheme) -> some View {
        let appearance = ChromeAppearance(paper)
        return environment(\.chromeAppearance, appearance)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    /// Popover content for `paper`: the popover's own appearance and background.
    func chromePopover(_ paper: PaperTheme) -> some View {
        let appearance = ChromeAppearance(paper)
        return chromeAppearance(paper)
            .preferredColorScheme(appearance.colorScheme)
            .presentationBackground(appearance.popoverBackground)
    }

    /// Chrome glass in `shape`, per the environment's ``ChromeAppearance``; frosted adds a hairline and soft shadow.
    func chromeGlass(in shape: some Shape) -> some View {
        modifier(ChromeGlass(shape: shape))
    }
}

private struct ChromeGlass<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.chromeAppearance) private var appearance

    func body(content: Content) -> some View {
        if let appearance {
            content
                .glassEffect(appearance.glass, in: shape)
                .overlay {
                    if appearance == .frosted {
                        shape.stroke(Tokens.Colors.chromeBorder, lineWidth: 0.5).allowsHitTesting(false)
                    }
                }
                .background {
                    if appearance == .frosted {
                        shape.fill(Tokens.Colors.chromeFrost).shadow(Tokens.Shadows.chrome)
                    }
                }
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}
