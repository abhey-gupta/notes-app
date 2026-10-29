import DesignSystem
import InkModel
import SwiftUI

/// The open-notebook tabs in the editor bar (#191): plain titles that never truncate, the showing one on a
/// subtle fill with its ×, and a "+N" chip listing the tabs the row has no room for. + leaves for the
/// library, where tapping a cover opens it as a tab.
struct TabStrip: View {
    struct Tab: Identifiable, Hashable {
        let id: NotebookID
        let title: String
    }

    let tabs: [Tab]
    let active: NotebookID?
    let onSelect: (NotebookID) -> Void
    let onClose: (NotebookID) -> Void
    let onCloseOthers: () -> Void
    let onAdd: () -> Void

    /// Natural width of each tab in its current style, measured off screen.
    @State private var widths: [NotebookID: CGFloat] = [:]
    @State private var chipWidth: CGFloat = 0
    @State private var stripWidth: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let spacing = Tokens.Spacing.xs
    private static let height: CGFloat = 36
    private static let corner: CGFloat = 10

    var body: some View {
        let shown = visible
        HStack(spacing: Self.spacing) {
            ForEach(shown, id: \.self) { index in
                tab(tabs[index])
            }
            if shown.count < tabs.count {
                overflow(hidden: tabs.count - shown.count)
            }
            ToolButton(.add, "Open another notebook", size: Tokens.Size.compactToolButton, action: onAdd)
                .accessibilityIdentifier("addTab")
                .accessibilityHint("Goes to the library")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { stripWidth = $0 }
        .background { measurements }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabs")
    }

    /// Indices of the tabs that fit (``TabFit``), the showing one always among them.
    private var visible: [Int] {
        let scale = typeSize.chromeScale
        let available = stripWidth - Tokens.Size.compactToolButton.width * scale - Self.spacing
        let widths = tabs.map { widths[$0.id] ?? 0 }
        return TabFit.visible(
            widths: widths, available: max(available, 0), spacing: Self.spacing, overflow: chipWidth,
            active: active.flatMap { id in tabs.firstIndex { $0.id == id } }
        )
    }

    /// Every tab and the widest chip, laid out invisibly so their natural widths are known before the row
    /// decides what fits.
    private var measurements: some View {
        HStack(spacing: Self.spacing) {
            ForEach(tabs) { tab in
                self.tab(tab)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { widths[tab.id] = $0 }
            }
            overflow(hidden: tabs.count)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { chipWidth = $0 }
        }
        .fixedSize()
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tab(_ tab: Tab) -> some View {
        let scale = typeSize.chromeScale
        let isActive = tab.id == active
        return HStack(spacing: 0) {
            Button {
                onSelect(tab.id)
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
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityHint(isActive ? "" : "Shows this notebook")
            .accessibilityIdentifier("tab-\(tab.title)")
            if isActive {
                Button {
                    onClose(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(Tokens.Colors.textTertiary)
                        .frame(width: 26 * scale, height: Self.height * scale)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
                .accessibilityIdentifier("closeTab")
            }
        }
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: Self.corner).fill(Tokens.Colors.subtleFill)
            }
        }
        .contextMenu {
            Button("Close Tab", systemImage: "xmark") { onClose(tab.id) }
            if tabs.count > 1 {
                Button("Close Other Tabs") {
                    onSelect(tab.id)
                    onCloseOthers()
                }
            }
        }
    }

    /// "+N ⌄": every open tab, the showing one ticked, and Close Other Tabs.
    private func overflow(hidden: Int) -> some View {
        let scale = typeSize.chromeScale
        return Menu {
            Picker("Open notebooks", selection: selection) {
                ForEach(tabs) { tab in
                    Text(tab.title).tag(Optional(tab.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Close Other Tabs") { onCloseOthers() }
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Text("+\(hidden)")
                    .scaledFont(size: 14, weight: .semibold)
                    .monospacedDigit()
                Image(systemName: Symbol.disclosure.name)
                    .scaledFont(size: 10, weight: .semibold)
            }
            .foregroundStyle(Tokens.Colors.textSecondary)
            .padding(.horizontal, Tokens.Spacing.m)
            .frame(height: Self.height * scale)
            .background(RoundedRectangle(cornerRadius: Self.corner).fill(Tokens.Colors.subtleFill))
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("More tabs")
        .accessibilityValue("\(hidden) hidden")
        .accessibilityIdentifier("moreTabs")
    }

    private var selection: Binding<NotebookID?> {
        Binding { active } set: { id in
            if let id {
                onSelect(id)
            }
        }
    }
}
