import DesignSystem
import SwiftUI

/// One-time caption (#129) telling the user the page edges can be held and dragged. Sits just inside the
/// right page edge at the fitted zoom (the page stops 96 pt short of the screen), vertically centered,
/// in the chrome's glass. Fades after a few seconds or on the first grab (`EditorState.dismissWidenHint`).
struct WidenHint: View {
    var body: some View {
        GlassCapsule(
            height: Tokens.Size.focusPillHeight,
            leading: Tokens.Spacing.m,
            trailing: Tokens.Spacing.m,
            spacing: Tokens.Spacing.xs
        ) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Colors.textSecondary)
            Text("Hold a page edge to widen")
                .font(.chromeTitle)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 96 + Tokens.Spacing.m)
        .allowsHitTesting(false)
        .accessibilityIdentifier("widenHint")
        .accessibilityLabel("Hold a page edge to widen the pages")
    }
}
