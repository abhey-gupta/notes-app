import SwiftUI

/// Dynamic Type for chrome (#45): text scales with the user's size and the glass capsules grow with it, up
/// to ``chromeLimit`` (AX1). Mock sizes are the `.large` (default) sizes.
public extension DynamicTypeSize {
    /// Largest size chrome follows; bigger settings render chrome at this size.
    static let chromeLimit: DynamicTypeSize = .accessibility1

    /// Factor applied to chrome geometry (capsule thickness, buttons, swatches, popover width). 1 at and
    /// below the default size, so smaller text never shrinks a 44 pt target.
    var chromeScale: CGFloat {
        switch min(self, .chromeLimit) {
        case .xSmall, .small, .medium, .large: 1
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        default: 1.5
        }
    }
}

public extension View {
    /// SF Pro at the mock's point `size` (at the default text size), scaled with Dynamic Type like
    /// `relativeTo`. Use for one-off chrome text that has no `Font` token.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, style: style))
    }
}

private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}
