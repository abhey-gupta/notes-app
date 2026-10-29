import DesignSystem
import SwiftUI
import Tools

/// Tools, the photo button and quick colors, laid out along `axis` so the same content docks on any edge.
/// Undo/redo live in the ``EditorBar`` (#191); compact chrome keeps undo here. ARCHITECTURE §7 calls this `ToolbarContent`; renamed so it
/// doesn't shadow SwiftUI's protocol
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
    @State private var assigned = [Int](repeating: 0, count: ToolSettings.maxQuickColors)
    @State private var showsPhotos = false
    @State private var showsColors = false
    @Environment(\.dynamicTypeSize) private var typeSize
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
        if isCompact, tools.palette.count > Self.compactVisibleColors {
            // A phone-width bar shows three; the rest scroll.
            ScrollView(.horizontal) {
                HStack(spacing: Tokens.Spacing.hairline) { swatches }
            }
            .scrollIndicators(.hidden)
            .frame(width: compactSwatchesWidth)
        } else {
            swatches
        }
        colorsButton
        if isCompact {
            ChromeSeparator(axis: axis)
            ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
                .disabled(!state.canUndo)
        }
    }

    /// The palette ``ToolState/paletteTool`` uses: the highlighter's while it's current, else the pen's (#125).
    private var swatches: some View {
        ForEach(Array(tools.palette.enumerated()), id: \.offset) { index, color in
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
    }

    /// ⌄ after the swatches: the quick-color editor (#125), opening away from the dock.
    private var colorsButton: some View {
        let scale = typeSize.chromeScale
        let horizontal = axis == .horizontal
        return Button {
            showsColors.toggle()
        } label: {
            Image(systemName: Symbol.disclosure.name)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Tokens.Colors.textTertiary)
                .frame(
                    width: (horizontal ? 26 : Tokens.Size.compactToolButton.width) * scale,
                    height: (horizontal ? Tokens.Size.compactToolButton.height : 26) * scale
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsColors, arrowEdge: arrowEdge) {
            QuickColorsPopover(tools: tools, paper: paper)
                .presentationCompactAdaptation(.popover)
                .dynamicTypeSize(...DynamicTypeSize.chromeLimit)
        }
        .accessibilityLabel("Edit colors")
        .accessibilityIdentifier("editColors")
    }

    private static let compactVisibleColors = 3

    private var compactSwatchesWidth: CGFloat {
        let swatch = (Tokens.Size.swatch + 2 * Tokens.Size.swatchRingOuter) * typeSize.chromeScale
        let count = CGFloat(Self.compactVisibleColors)
        return count * swatch + (count - 1) * Tokens.Spacing.hairline
    }

    /// A phone-width bar has no room for the laser pointer: it's in ⋯ (``MoreMenu``).
    static let compactTools = Tool.allCases.filter { $0 != .laser }

    private func assign(_ index: Int) {
        tools.setQuickColor(tools.paletteColor, at: index)
        assigned[index] += 1
    }
}

/// "3 of 12" at the bottom trailing corner, focus mode only (#191): the bar's counter hides with the bar.
struct PageIndicator: View {
    let page: (current: Int, total: Int)
    let onSize: (CGSize) -> Void

    var body: some View {
        GlassPill.pageIndicator(current: page.current, total: page.total)
            .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
            .opacity(0.7)
            .accessibilityIdentifier("pageIndicator")
            .accessibilityHint("Current page")
            .padding(.bottom, Tokens.Spacing.chromeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
