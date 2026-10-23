import DesignSystem
import SwiftUI

/// Where the tools capsule sits. Product decision: one dynamic toolbar, top by default, draggable and
/// spring-snapped to any edge, pinch to compact (#26). #13 renders each dock statically; `top` is polished.
enum ToolbarDock: String, CaseIterable, Identifiable {
    case top, bottom, left, right

    static let defaultsKey = "toolbarDock"

    var id: Self {
        self
    }

    var axis: Axis {
        switch self {
        case .top, .bottom: .horizontal
        case .left, .right: .vertical
        }
    }

    var displayName: String {
        rawValue.capitalized
    }

    fileprivate var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

/// Editor chrome (mock §02): nav capsule, docked tools, pages capsule, page pill, all in one `GlassChrome` so
/// collapsing to the compact pill (mock §05) is a `glassEffectID` morph.
struct ToolbarHost: View {
    let dock: ToolbarDock
    /// Compact pill instead of the expanded chrome: focus mode now, pinch-to-compact later (#26).
    let isCompact: Bool
    let title: String
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    let state: EditorState
    let page: (current: Int, total: Int)
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    enum ChromeID: Hashable {
        case nav, tools, pages
    }

    var body: some View {
        GlassChrome {
            ZStack {
                if !isCompact {
                    HStack(alignment: .top) {
                        navCapsule.chromeID(.nav, in: glass, transition: glassTransition)
                        Spacer(minLength: Tokens.Spacing.m)
                        pagesCapsule.chromeID(.pages, in: glass, transition: glassTransition)
                    }
                    .padding(.top, Tokens.Spacing.s)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                tools
                    .padding(toolsInsets)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dock.alignment)
                pagePill
            }
            .padding(.horizontal, Tokens.Spacing.chromeInset)
        }
        .animation(reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.morph, value: isCompact)
        .animation(Tokens.Motion.morph, value: dock)
    }

    private var ink: Color {
        paper.ink(state.inkRole).color
    }

    private var toolsInsets: EdgeInsets {
        switch dock {
        case .top: EdgeInsets(top: Tokens.Spacing.s, leading: 0, bottom: 0, trailing: 0)
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: Tokens.Spacing.chromeInset, trailing: 0)
        case .left, .right: EdgeInsets()
        }
    }

    private var glassTransition: GlassEffectTransition {
        reduceMotion ? .materialize : .matchedGeometry
    }

    // MARK: Tools

    @ViewBuilder
    private var tools: some View {
        if isCompact {
            FocusPill(tool: state.tool.symbol, ink: ink, onTool: state.exitFocus, onExpand: state.exitFocus)
                .contentShape(.capsule)
                .onTapGesture(perform: state.exitFocus)
                .chromeID(.tools, in: glass, transition: glassTransition)
                .accessibilityIdentifier("focusPill")
                .padding(dock == .top ? .top : [], (Tokens.Size.capsuleHeight - Tokens.Size.focusPillHeight) / 2)
        } else if dock.axis == .horizontal {
            GlassCapsule {
                EditorToolbarContent(state: state, paper: paper, axis: .horizontal)
            }
            .chromeID(.tools, in: glass, transition: glassTransition)
        } else {
            VStack(spacing: Tokens.Spacing.hairline) {
                EditorToolbarContent(state: state, paper: paper, axis: .vertical)
            }
            .padding(.vertical, Tokens.Spacing.s)
            .frame(width: Tokens.Size.capsuleHeight)
            .glassEffect(.regular, in: .capsule)
            .chromeID(.tools, in: glass, transition: glassTransition)
        }
    }

    // MARK: Capsules

    private var navCapsule: some View {
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

    private var pagesCapsule: some View {
        GlassCapsule {
            ToolButton(.pages, "Pages") {}
            ToolButton(.share, "Share") {}
            Menu {
                Button("Focus mode", systemImage: Symbol.focus.name) { state.enterFocus() }
                #if DEBUG
                    Picker("Toolbar dock (debug)", selection: dockBinding) {
                        ForEach(ToolbarDock.allCases) { Text($0.displayName).tag($0) }
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
            Binding {
                dock
            } set: {
                UserDefaults.standard.set($0.rawValue, forKey: ToolbarDock.defaultsKey)
            }
        }
    #endif

    private var pagePill: some View {
        Button(action: state.exitFocus) {
            GlassPill.pageIndicator(current: page.current, total: page.total)
        }
        .buttonStyle(.plain)
        .opacity(isCompact ? 0.7 : 1)
        .accessibilityIdentifier("pageIndicator")
        .padding(.bottom, Tokens.Spacing.chromeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// Tools, quick colors, undo/redo, laid out along `axis` so the same content docks on any edge.
/// ARCHITECTURE §7 calls this `ToolbarContent`; renamed so it doesn't shadow SwiftUI's protocol in App.
struct EditorToolbarContent: View {
    let state: EditorState
    let paper: PaperTheme
    let axis: Axis

    var body: some View {
        ForEach(EditorState.Tool.allCases) { tool in
            ToolButton(tool.symbol, tool.label, isActive: state.tool == tool, ink: paper.ink(state.inkRole).color) {
                state.tool = tool
            }
        }
        separator
        ForEach(Array(Tokens.quickColors.enumerated()), id: \.offset) { index, role in
            ColorSwatch(paper.ink(role).color, label: role.label, isSelected: state.quickColor == index) {
                state.quickColor = index
                if !state.tool.inks {
                    state.tool = .pen
                }
            }
        }
        separator
        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
            .disabled(!state.canUndo)
        ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
            .disabled(!state.canRedo)
    }

    @ViewBuilder
    private var separator: some View {
        if axis == .horizontal {
            ChromeSeparator()
        } else {
            Capsule()
                .fill(Tokens.Colors.separator)
                .frame(width: Tokens.Size.separator.height, height: Tokens.Size.separator.width)
                .padding(.vertical, Tokens.Spacing.s)
                .accessibilityHidden(true)
        }
    }
}

private extension InkRole {
    var label: String {
        switch self {
        case .primary: "Black"
        case .blue: "Blue"
        case .red: "Red"
        case .accent: "Amber"
        }
    }
}

private extension View {
    func chromeID(_ id: ToolbarHost.ChromeID, in namespace: Namespace.ID, transition: GlassEffectTransition) -> some View {
        glassEffectID(id, in: namespace)
            .glassEffectTransition(transition)
    }
}
