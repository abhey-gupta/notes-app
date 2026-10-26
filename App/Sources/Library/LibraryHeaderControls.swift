import DesignSystem
import SwiftUI

/// Library header glass: search field, New, round icon buttons. Compact chrome (#118) widens the field and
/// shrinks New to a round +.
struct LibrarySearchField: View {
    @Binding var query: String

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isCompactLayout) private var isCompactLayout

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.search.name)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .accessibilityHidden(true)
            TextField("Search notebooks", text: $query)
                .scaledFont(size: 15)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(width: isCompactLayout ? nil : 250 * typeSize.chromeScale)
        .frame(maxWidth: isCompactLayout ? .infinity : nil, minHeight: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct NewNotebookButton: View {
    let action: () -> Void

    @Environment(\.isCompactLayout) private var isCompactLayout

    var body: some View {
        Button(action: action) {
            if isCompactLayout {
                Image(systemName: Symbol.add.name)
                    .scaledFont(size: 17, weight: .semibold)
                    .frame(width: 28, height: 28)
            } else {
                Label("New", systemImage: Symbol.add.name)
                    .font(.chromeTitle)
                    .padding(.horizontal, 2)
                    .frame(minHeight: 28)
            }
        }
        .foregroundStyle(Tokens.Colors.libraryBackground)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(isCompactLayout ? .circle : .capsule)
        .tint(Tokens.Colors.textPrimary.color)
        .fixedSize()
        .accessibilityLabel("New")
        .accessibilityIdentifier("newNotebook")
    }
}

/// 40 pt glass circle: sidebar, settings, close.
struct GlassCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}
