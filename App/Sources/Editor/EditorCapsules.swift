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
    /// Current page (1-based) and page count, for export.
    let page: (current: Int, total: Int)
    let isNight: Bool

    @State private var showsShare = false
    @State private var presenter = ActivityPresenter()

    var body: some View {
        GlassCapsule {
            ToolButton(.pages, "Pages") {}
            ToolButton(.share, "Share") { showsShare.toggle() }
                .background(ActivityAnchor(presenter: presenter))
                .popover(isPresented: $showsShare) {
                    SharePopover(state: state, page: page, isNight: isNight) { url in
                        showsShare = false
                        // Present once SwiftUI has started dismissing the popover.
                        Task {
                            try? await Task.sleep(for: .milliseconds(50))
                            presenter.share(url)
                        }
                    }
                }
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
///
/// Long-press a quick color to store the pen's current color in that slot (#27).
struct EditorToolbarContent: View {
    let tools: ToolState
    let state: EditorState
    let paper: PaperTheme
    let axis: Axis
    /// Tap on the already-current tool.
    let onReselect: (Tool) -> Void
    /// Each tool button's frame in ``ToolbarHost/capsuleSpace`` (popover anchors).
    let onToolFrame: (Tool, CGRect) -> Void

    /// Bumped per slot when a long-press assigns it: pops the swatch and plays a haptic.
    @State private var assigned = [Int](repeating: 0, count: ToolSettings.quickColorCount)

    var body: some View {
        let ink = tools.currentColor.color(on: paper)
        ForEach(Tool.allCases, id: \.self) { tool in
            ToolButton(tool.symbol, tool.label, isActive: tools.tool == tool, ink: ink) {
                if tools.select(tool) {
                    onReselect(tool)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ToolbarHost.capsuleSpace)) } action: { onToolFrame(tool, $0) }
        }
        ChromeSeparator(axis: axis)
        ForEach(Array(tools.quickColors.enumerated()), id: \.offset) { index, color in
            ColorSwatch(color.color(on: paper), label: color.label, isSelected: tools.activeQuickColor == index) {
                tools.selectQuickColor(index)
            }
            .keyframeAnimator(initialValue: 1.0, trigger: assigned[index]) { swatch, scale in
                swatch.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.25, duration: 0.14, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in assign(index) })
            .accessibilityAction(named: "Set to current pen color") { assign(index) }
            .sensoryFeedback(.success, trigger: assigned[index])
        }
        ChromeSeparator(axis: axis)
        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
            .disabled(!state.canUndo)
        ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
            .disabled(!state.canRedo)
    }

    private func assign(_ index: Int) {
        tools.setQuickColor(tools.pen.color, at: index)
        assigned[index] += 1
    }
}
