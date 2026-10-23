import DesignSystem
import SwiftUI
import Tools

/// Back, notebook title and paper/template menu (mock §02, left).
struct NavCapsule: View {
    let title: String
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    let onBack: () -> Void

    var body: some View {
        GlassCapsule(leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.l, spacing: 0) {
            ToolButton(.back, "Library", action: onBack)
            Menu {
                Picker("Paper", selection: $paper) {
                    ForEach(PaperTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                Picker("Template", selection: $pattern) {
                    ForEach(PaperPattern.allCases) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.chromeTitle)
                        .foregroundStyle(Tokens.Colors.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: Symbol.disclosure.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.Colors.textTertiary)
                }
                .frame(height: Tokens.Size.toolButton.height)
                .contentShape(.rect)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), notebook options")
        }
    }
}

/// Pages, share, more (mock §02, right). DEBUG adds a dock picker to the menu.
struct PagesCapsule: View {
    let tools: ToolState
    let state: EditorState

    var body: some View {
        GlassCapsule {
            ToolButton(.pages, "Pages") {}
            ToolButton(.share, "Share") {}
            Menu {
                Button("Focus mode", systemImage: Symbol.focus.name) { state.enterFocus() }
                #if DEBUG
                    Picker("Toolbar dock (debug)", selection: dockBinding) {
                        ForEach(ToolbarDock.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                #endif
            } label: {
                Image(systemName: Symbol.more.name)
                    .font(.system(size: Tokens.Size.toolIcon))
                    .foregroundStyle(Tokens.Colors.icon)
                    .frame(width: Tokens.Size.toolButton.width, height: Tokens.Size.toolButton.height)
                    .contentShape(.capsule)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("More")
        }
    }

    #if DEBUG
        private var dockBinding: Binding<ToolbarDock> {
            Binding { tools.dock } set: { tools.dock = $0 }
        }
    #endif
}

/// Tools, quick colors, undo/redo, laid out along `axis` so the same content docks on any edge.
/// ARCHITECTURE §7 calls this `ToolbarContent`; renamed so it doesn't shadow SwiftUI's protocol in App.
struct EditorToolbarContent: View {
    let tools: ToolState
    let state: EditorState
    let paper: PaperTheme
    let axis: Axis
    /// Tap on the already-current tool.
    let onReselect: (Tool) -> Void

    var body: some View {
        let ink = tools.currentColor.color(on: paper)
        ForEach(Tool.allCases, id: \.self) { tool in
            ToolButton(tool.symbol, tool.label, isActive: tools.tool == tool, ink: ink) {
                if tools.select(tool) {
                    onReselect(tool)
                }
            }
        }
        ChromeSeparator(axis: axis)
        ForEach(Array(tools.quickColors.enumerated()), id: \.offset) { index, color in
            ColorSwatch(color.color(on: paper), label: color.label, isSelected: tools.activeQuickColor == index) {
                tools.selectQuickColor(index)
            }
        }
        ChromeSeparator(axis: axis)
        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
            .disabled(!state.canUndo)
        ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
            .disabled(!state.canRedo)
    }
}
