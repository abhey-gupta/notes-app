import DesignSystem
import SwiftUI
import Tools

/// Back and notebook title; the title opens the notebook menu: Rename, Move to Folder, Duplicate, Delete (#126).
struct NavCapsule: View {
    let title: String
    let menu: NotebookMenu
    let onBack: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let scale = typeSize.chromeScale
        GlassCapsule(leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.l, spacing: 0) {
            ToolButton(.back, "Library", action: onBack)
            Menu {
                menu
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.chromeTitle)
                        .foregroundStyle(Tokens.Colors.chromeText)
                        .lineLimit(1)
                        .frame(maxWidth: 220 * scale, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: Symbol.disclosure.name)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Tokens.Colors.chromeHeader)
                }
                .frame(height: Tokens.Size.toolButton.height * scale)
                .contentShape(.rect)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), notebook options")
        }
    }
}

/// Pages, share, more (mock §02, right). More opens ``PagePopover``: paper, template, focus mode.
struct PagesCapsule: View {
    let tools: ToolState
    let state: EditorState
    /// Current page (1-based) and page count, for export.
    let page: (current: Int, total: Int)
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern

    @State private var showsShare = false
    @State private var showsMore = false
    @State private var presenter = ActivityPresenter()

    var body: some View {
        GlassCapsule {
            ToolButton(.pages, "Pages") { state.pages.present() }
                .accessibilityHint("Shows all pages")
            ToolButton(.share, "Share") { showsShare.toggle() }
                .background(ActivityAnchor(presenter: presenter))
                .popover(isPresented: $showsShare) {
                    SharePopover(state: state, page: page, isNight: paper == .night) { url in
                        showsShare = false
                        // Present once SwiftUI has started dismissing the popover.
                        Task {
                            try? await Task.sleep(for: .milliseconds(50))
                            presenter.share(url)
                        }
                    }
                    .chromePopover(paper)
                }
            ToolButton(.more, "More") { showsMore.toggle() }
                .accessibilityValue("\(paper.displayName) paper, \(pattern.displayName)")
                .popover(isPresented: $showsMore) {
                    PagePopover(tools: tools, paper: $paper, pattern: $pattern, keepsExactColors: exactColorsBinding) {
                        showsMore = false
                        state.enterFocus()
                    }
                    .chromePopover(paper)
                }
        }
    }

    private var exactColorsBinding: Binding<Bool> {
        Binding { state.keepsExactColors } set: { state.onKeepsExactColors($0) }
    }
}

/// Tools, quick colors, undo/redo, laid out along `axis` so the same content docks on any edge.
/// ARCHITECTURE §7 calls this `ToolbarContent`; renamed so it doesn't shadow SwiftUI's protocol in App.
///
/// Quick colors are the current inking tool's (pen, or highlighter while it is current; #125). Long-press one to
/// store the tool's current color in that slot (#27); the ⌄ after them opens ``QuickColorsEditor``.
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
    @State private var assigned = [Int](repeating: 0, count: ToolSettings.quickColorCounts.upperBound)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = tools.currentColor.color(on: paper)
        ForEach(Tool.allCases, id: \.self) { tool in
            ToolButton(tool.symbol, tool.label, isActive: tools.tool == tool, ink: ink) {
                if tools.select(tool) {
                    onReselect(tool)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ToolbarHost.capsuleSpace)) } action: { onToolFrame(tool, $0) }
            .accessibilityValue(tools.accessibilityValue(of: tool))
            .accessibilityHint(tools.tool == tool && tool != .lasso ? "Shows \(tool.label.lowercased()) options" : "")
        }
        ChromeSeparator(axis: axis)
        ForEach(Array(tools.currentQuickColors.enumerated()), id: \.offset) { index, color in
            ColorSwatch(color.color(on: paper), label: color.label, isSelected: tools.activeQuickColor == index) {
                tools.selectQuickColor(index)
            }
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : assigned[index]) { swatch, scale in
                swatch.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.25, duration: 0.14, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in assign(index) })
            .accessibilityHint("Quick color. Touch and hold to store the current color here.")
            .accessibilityAction(named: "Set to current color") { assign(index) }
            .sensoryFeedback(.success, trigger: assigned[index])
        }
        QuickColorsButton(tools: tools, paper: paper)
        ChromeSeparator(axis: axis)
        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
            .disabled(!state.canUndo)
        ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
            .disabled(!state.canRedo)
    }

    private func assign(_ index: Int) {
        tools.setQuickColor(tools.currentColor, at: index)
        assigned[index] += 1
    }
}
