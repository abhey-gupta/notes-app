import DesignSystem
import InkModel
import SwiftUI

/// The open-notebook tabs in the editor bar (#191). Folded, they're one chip: the showing notebook's title
/// and a "3 ⌄" pill. Tap it and the strip unfolds in place: the chip becomes the showing tab, the others
/// slide out of it one after another, and the bar's other controls slide away. Plain titles that never
/// truncate; past the bar's width the strip scrolls. Any touch on the page folds it back (``EditorState``).
struct TabStrip: View {
    struct Tab: Identifiable, Hashable {
        let id: NotebookID
        let title: String
    }

    let tabs: [Tab]
    let active: NotebookID?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelect: (NotebookID) -> Void
    let onClose: (NotebookID) -> Void
    let onCloseOthers: () -> Void
    let onAdd: () -> Void
    /// Opens a tab in split view (#175), beside the showing one; `nil` where there's no split (compact).
    var onSplit: ((NotebookID) -> Void)?

    @Namespace private var strip
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let splitSymbol = "rectangle.split.2x1"
    private static let spacing = Tokens.Spacing.xs
    private static let height: CGFloat = 36

    var body: some View {
        if isExpanded {
            expanded
        } else {
            chip
        }
    }

    private var activeTab: Tab? {
        tabs.first { $0.id == active }
    }

    /// Folded: title + "N ⌄".
    private var chip: some View {
        let scale = typeSize.chromeScale
        return Button(action: onToggle) {
            HStack(spacing: Tokens.Spacing.s) {
                Text(activeTab?.title ?? "")
                    .scaledFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Tokens.Colors.textPrimary)
                HStack(spacing: 3) {
                    Text("\(tabs.count)")
                        .scaledFont(size: 11.5, weight: .semibold)
                        .monospacedDigit()
                    Image(systemName: Symbol.disclosure.name)
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                }
                .foregroundStyle(Tokens.Colors.textPrimary)
                .padding(.leading, 8)
                .padding(.trailing, 7)
                .frame(height: 22 * scale)
                .background(Capsule().fill(Tokens.Colors.subtleFill))
            }
            .padding(.leading, Tokens.Spacing.l)
            .padding(.trailing, Tokens.Spacing.s)
            .frame(height: Self.height * scale)
            .background(Capsule().fill(Tokens.Colors.subtleFill))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .matchedGeometryEffect(id: "active", in: strip)
        .contextMenu {
            if let onSplit {
                Menu("Open in Split View", systemImage: Self.splitSymbol) {
                    ForEach(tabs) { tab in
                        Button(tab.id == active ? "\(tab.title) (again)" : tab.title) { onSplit(tab.id) }
                    }
                }
            }
        }
        .accessibilityLabel(activeTab?.title ?? "Tabs")
        .accessibilityValue(tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs")
        .accessibilityHint("Shows the open notebooks")
        .accessibilityIdentifier("tabs")
    }

    /// Unfolded: every tab, the showing one where the chip was, then +.
    private var expanded: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.spacing) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    self.tab(tab)
                        .transition(slide(index))
                }
                ToolButton(.add, "Open another notebook", size: Tokens.Size.compactToolButton, action: onAdd)
                    .accessibilityIdentifier("addTab")
                    .accessibilityHint("Goes to the library")
                    .transition(slide(tabs.count))
            }
            .padding(.horizontal, Tokens.Spacing.xs)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabStrip")
    }

    /// Tabs slide out of the chip one after another (and back into it, in reverse).
    private func slide(_ index: Int) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let delay = Double(index) * 0.03
        return .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity).animation(Tokens.Motion.morph.delay(delay)),
            removal: .move(edge: .leading).combined(with: .opacity).animation(Tokens.Motion.reducedMorph)
        )
    }

    private func closeButton(_ tab: Tab) -> some View {
        Button {
            onClose(tab.id)
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(Tokens.Colors.textTertiary)
                .frame(width: 26 * typeSize.chromeScale, height: Self.height * typeSize.chromeScale)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close tab")
        .accessibilityIdentifier("closeTab")
    }

    private func tab(_ tab: Tab) -> some View {
        let scale = typeSize.chromeScale
        let isActive = tab.id == active
        return HStack(spacing: 0) {
            Button {
                isActive ? onToggle() : onSelect(tab.id)
            } label: {
                Text(tab.title)
                    .scaledFont(size: 14, weight: isActive ? .semibold : .medium)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(isActive ? Tokens.Colors.textPrimary : Tokens.Colors.textSecondary)
                    .padding(.leading, Tokens.Spacing.l)
                    .padding(.trailing, isActive ? Tokens.Spacing.xs : Tokens.Spacing.l)
                    .frame(height: Self.height * scale)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Dragged onto the page, it opens in split view (#175).
            .draggable(NotebookReference(id: tab.id)) {
                Text(tab.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .frame(height: Self.height)
                    .background(Capsule().fill(.regularMaterial))
            }
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isActive ? "Folds the tabs" : "Shows this notebook")
            .accessibilityIdentifier("tab-\(tab.title)")
            if isActive {
                closeButton(tab)
            }
        }
        .background {
            if isActive {
                Capsule().fill(Tokens.Colors.subtleFill)
            }
        }
        .matchedGeometryEffect(id: isActive ? "active" : "tab-\(tab.id)", in: strip)
        .contextMenu {
            if let onSplit {
                Button("Open in Split View", systemImage: Self.splitSymbol) { onSplit(tab.id) }
            }
            Button("Close Tab", systemImage: "xmark") { onClose(tab.id) }
            if tabs.count > 1 {
                Button("Close Other Tabs") {
                    onSelect(tab.id)
                    onCloseOthers()
                }
            }
        }
    }
}
