import DesignSystem
import SwiftUI
import Tools

/// Back, notebook title and paper/template menu (mock §02, left).
struct NavCapsule: View {
    let title: String
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    /// "Keep exact colors", offered on Night paper.
    @Binding var keepsExactColors: Bool
    let onBack: () -> Void
    /// Whole capsule's width budget (``maxWidth(_:)``).
    private var maxWidth: CGFloat = .infinity

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let scale = typeSize.chromeScale
        // The title takes what the budget leaves (#176): 64-100 pt (~10 characters), tail-truncated. Below 64
        // the capsule overflows its budget and a top-docked toolbar drops a row.
        WidthLimit(max: maxWidth) {
            GlassCapsule(leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.l, spacing: 0) {
                ToolButton(.back, "Library", action: onBack)
                Menu {
                    // Full title, since the pill truncates it (#176).
                    Section(title) {
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
                        if paper == .night {
                            Toggle("Keep exact colors", systemImage: "eyedropper", isOn: $keepsExactColors)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        WidthLimit(min: 64 * scale, max: 100 * scale) {
                            Text(title)
                                .font(.chromeTitle)
                                .foregroundStyle(Tokens.Colors.textPrimary)
                                .lineLimit(1)
                                .accessibilityIdentifier("notebookTitle")
                        }
                        Image(systemName: Symbol.disclosure.name)
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(Tokens.Colors.textTertiary)
                    }
                    .frame(height: Tokens.Size.toolButton.height * scale)
                    .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), notebook options")
                .accessibilityValue("\(paper.displayName) paper, \(pattern.displayName)")
            }
        }
    }

    /// Caps the capsule at `width` by tail-truncating the title (#176).
    func maxWidth(_ width: CGFloat) -> Self {
        var capsule = self
        capsule.maxWidth = width
        return capsule
    }
}

/// Lays its child out at its ideal width if that's within `min...max` (and the proposal), else squeezed to the
/// clamped width (a title tail-truncates), unless even squeezed it won't fit: then whole, overflowing.
/// Unlike `frame(maxWidth:)` it never grows past what the child wants.
private struct WidthLimit: Layout {
    var min: CGFloat = 0
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(limited(proposal, child))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: limited(proposal, child))
    }

    private func limited(_ proposal: ProposedViewSize, _ child: LayoutSubview) -> ProposedViewSize {
        let width = Swift.max(Swift.min(proposal.width ?? max, max), min)
        let whole = ProposedViewSize(width: nil, height: proposal.height)
        let squeezed = ProposedViewSize(width: width, height: proposal.height)
        let fits = { (size: ProposedViewSize) in child.sizeThatFits(size).width <= width }
        return !fits(whole) && fits(squeezed) ? squeezed : whole
    }
}

/// Pages, share, more (mock §02, right). DEBUG adds a dock picker to the menu.
///
/// Compact chrome (#118): pages · ⋯ only; Share and Add Photo move into ⋯ and open from it, and focus mode
/// (regular chrome only) leaves the menu.
struct PagesCapsule: View {
    let tools: ToolState
    let state: EditorState
    /// Current page (1-based) and page count, for export.
    let page: (current: Int, total: Int)
    let paper: PaperTheme
    var isCompact = false

    @State private var showsShare = false
    @State private var showsPhotos = false
    @State private var presenter = ActivityPresenter()
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GlassCapsule {
            ToolButton(.pages, "Pages") { state.pages.present() }
                .accessibilityHint("Shows all pages")
            if isCompact {
                more
                    .background(ActivityAnchor(presenter: presenter))
                    .popover(isPresented: $showsShare) { sharePopover }
                    .background {
                        Color.clear.popover(isPresented: $showsPhotos) {
                            PhotoFlyout(paper: paper) { data in
                                showsPhotos = false
                                state.insertPhoto(data)
                            }
                        }
                    }
            } else {
                ToolButton(.share, "Share") { showsShare.toggle() }
                    .background(ActivityAnchor(presenter: presenter))
                    .popover(isPresented: $showsShare) { sharePopover }
                more
            }
        }
    }

    private var sharePopover: some View {
        SharePopover(state: state, page: page, isNight: paper.isDark) { url in
            showsShare = false
            // Present once SwiftUI has started dismissing the popover.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                presenter.share(url)
            }
        }
        .chromePopover(for: paper)
        .presentationCompactAdaptation(.popover)
    }

    private var more: some View {
        let scale = typeSize.chromeScale
        return Menu {
            if isCompact {
                Button("Share", systemImage: Symbol.share.name) { showsShare = true }
                Button("Add Photo", systemImage: Symbol.photo.name) { showsPhotos = true }
                Toggle("Laser Pointer", systemImage: Symbol.laser.name, isOn: laserBinding)
            } else {
                Button("Focus mode", systemImage: Symbol.focus.name) { state.enterFocus() }
            }
            #if DEBUG
                Picker("Toolbar dock (debug)", selection: dockBinding) {
                    ForEach(ToolbarDock.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            #endif
        } label: {
            Image(systemName: Symbol.more.name)
                .font(.system(size: Tokens.Size.toolIcon * scale))
                .foregroundStyle(Tokens.Colors.icon)
                .frame(width: Tokens.Size.toolButton.width * scale, height: Tokens.Size.toolButton.height * scale)
                .contentShape(.capsule)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    /// Off goes back to the tool before the laser.
    private var laserBinding: Binding<Bool> {
        Binding { tools.tool == .laser } set: { on in
            if on {
                _ = tools.select(.laser)
            } else if tools.tool == .laser {
                tools.switchToPrevious()
            }
        }
    }

    #if DEBUG
        private var dockBinding: Binding<ToolbarDock> {
            Binding { tools.dock } set: { tools.dock = $0 }
        }
    #endif
}

/// Tools, the photo button, quick colors, undo/redo, laid out along `axis` so the same content docks on
/// any edge. ARCHITECTURE §7 calls this `ToolbarContent`; renamed so it doesn't shadow SwiftUI's protocol
/// in App.
///
/// Long-press a quick color to store the pen's current color in that slot (#27). The photo button (#157)
/// is not a tool: it opens the ``PhotoFlyout`` (away from the dock, like tool options) and the current
/// tool stays; a tap on a photo closes the flyout and places it.
struct EditorToolbarContent: View {
    let tools: ToolState
    let state: EditorState
    let paper: PaperTheme
    let axis: Axis
    /// Popover edge carrying the arrow (faces the dock).
    let arrowEdge: Edge
    /// Compact chrome's bottom bar (#118): tools, quick colors, undo. Photos are in ⋯; redo is the
    /// three-finger tap.
    var isCompact = false
    /// Tap on the already-current tool.
    let onReselect: (Tool) -> Void
    /// Each tool button's frame in ``ToolbarHost/capsuleSpace`` (popover anchors).
    let onToolFrame: (Tool, CGRect) -> Void

    /// Bumped per slot when a long-press assigns it: pops the swatch and plays a haptic.
    @State private var assigned = [Int](repeating: 0, count: ToolSettings.quickColorCount)
    @State private var showsPhotos = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = tools.currentColor.color(on: paper)
        let toolSize = isCompact ? Tokens.Size.compactToolButton : Tokens.Size.toolButton
        ForEach(isCompact ? Self.compactTools : Tool.allCases, id: \.self) { tool in
            ToolButton(tool.symbol, tool.label, isActive: tools.tool == tool, ink: ink, size: toolSize) {
                if tools.select(tool) {
                    onReselect(tool)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ToolbarHost.capsuleSpace)) } action: { onToolFrame(tool, $0) }
            .accessibilityValue(tools.accessibilityValue(of: tool))
            .accessibilityHint(tools.tool == tool && tool != .lasso ? "Shows \(tool.label.lowercased()) options" : "")
        }
        if !isCompact {
            ToolButton(.photo, "Photo", isActive: showsPhotos, ink: ink, showsDot: false) {
                showsPhotos.toggle()
            }
            .popover(isPresented: $showsPhotos, arrowEdge: arrowEdge) {
                PhotoFlyout(paper: paper) { data in
                    showsPhotos = false
                    state.insertPhoto(data)
                }
            }
            .accessibilityIdentifier("photoButton")
            .accessibilityHint("Shows recent photos to add to the page")
        }
        ChromeSeparator(axis: axis)
        ForEach(Array(tools.quickColors.enumerated()), id: \.offset) { index, color in
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
            .accessibilityHint("Quick color. Touch and hold to store the current pen color here.")
            .accessibilityAction(named: "Set to current pen color") { assign(index) }
            .sensoryFeedback(.success, trigger: assigned[index])
        }
        ChromeSeparator(axis: axis)
        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
            .disabled(!state.canUndo)
        if !isCompact {
            ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
                .disabled(!state.canRedo)
        }
    }

    /// A phone-width bar has no room for the laser pointer: it's in ⋯ (``PagesCapsule``).
    static let compactTools = Tool.allCases.filter { $0 != .laser }

    private func assign(_ index: Int) {
        tools.setQuickColor(tools.pen.color, at: index)
        assigned[index] += 1
    }
}

/// "3 / 12" at the bottom trailing corner; dimmed in focus mode. Compact chrome (#118): above the bottom bar,
/// which takes the whole row on a phone.
struct PageIndicator: View {
    let page: (current: Int, total: Int)
    let isFocused: Bool
    let isCompactChrome: Bool
    let onSize: (CGSize) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GlassPill.pageIndicator(current: page.current, total: page.total)
            .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
            .opacity(isFocused ? 0.7 : 1)
            .accessibilityIdentifier("pageIndicator")
            .accessibilityHint("Current page")
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// Past the glass blend distance, so the pill doesn't melt into the bar.
    private static let barGap = Tokens.Spacing.glassBlend + Tokens.Spacing.xs

    private var bottom: CGFloat {
        let inset = Tokens.Spacing.chromeInset
        return isCompactChrome ? inset + Tokens.Size.capsuleHeight * typeSize.chromeScale + Self.barGap : inset
    }
}
