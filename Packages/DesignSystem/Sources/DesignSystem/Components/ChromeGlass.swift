import SwiftUI

/// Editor chrome glass, chosen by the paper it floats over (#122): paper-white tinted glass with dark text on
/// White and Cream, clear smoked glass with light text on Night. The chrome follows the notebook, not the
/// system appearance, so a popover over a white page never turns grey in dark mode (and vice versa).
///
/// Set once on the editor's chrome with ``SwiftUI/View/chromeGlass(for:)``; popover content uses
/// ``SwiftUI/View/chromePopover(for:)``. Glass components read it with ``SwiftUI/View/chromeGlassEffect(in:)``
/// and fall back to plain system glass where it isn't set (library, previews).
public enum ChromeGlass: Hashable, Sendable {
    case tinted, clear

    public init(for paper: PaperTheme) {
        self = paper.isDark ? .clear : .tinted
    }

    /// Scheme the chrome's text and icon tokens resolve in.
    public var colorScheme: ColorScheme {
        self == .clear ? .dark : .light
    }

    /// Capsule material. The color sits *behind* the glass (``backing``) rather than in a `Glass.tint`: glass
    /// darkens a tint by whatever is under it, so a light tint over the dark desk went khaki.
    public var glass: Glass {
        self == .clear ? .clear : .regular
    }

    /// Fill the glass samples instead of the desk or page.
    public var backing: Color {
        (self == .clear ? Tokens.Colors.chromeSmoke : Tokens.Colors.chromeTint).color
    }

    /// Wash laid over a popover's system glass.
    public var popoverTint: Color {
        (self == .clear ? Tokens.Colors.popoverSmoke : Tokens.Colors.popoverTint).color
    }
}

public extension EnvironmentValues {
    /// `nil` outside the editor chrome.
    @Entry var chromeGlass: ChromeGlass?
}

public extension View {
    /// Editor chrome over `paper`: its glass and the matching color scheme for every token inside.
    func chromeGlass(for paper: PaperTheme) -> some View {
        let chrome = ChromeGlass(for: paper)
        return environment(\.chromeGlass, chrome)
            .environment(\.colorScheme, chrome.colorScheme)
    }

    /// Popover content over `paper`: the popover's own scheme (its system glass follows) plus the chrome wash.
    func chromePopover(for paper: PaperTheme) -> some View {
        let chrome = ChromeGlass(for: paper)
        return background(chrome.popoverTint)
            .chromeGlass(for: paper)
            .preferredColorScheme(chrome.colorScheme)
    }

    /// Glass in `shape` from the environment's ``ChromeGlass``, or plain system glass.
    func chromeGlassEffect(in shape: some Shape) -> some View {
        modifier(ChromeGlassEffect(shape: shape))
    }
}

private struct ChromeGlassEffect<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.chromeGlass) private var chrome

    func body(content: Content) -> some View {
        content
            .glassEffect(chrome?.glass ?? .regular, in: shape)
            .background {
                if let chrome {
                    shape.fill(chrome.backing)
                }
            }
    }
}
