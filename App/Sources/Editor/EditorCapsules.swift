import DesignSystem
import SwiftUI
import Tools

/// Small glass ‹ back to the library (top leading). The title and paper options live in ⋯ (``PagesCapsule``).
struct BackCapsule: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        SlimCapsule {
            ToolButton(.back, "Library", size: Tokens.Size.focusToolButton, action: onBack)
                .accessibilityHint("Closes \(title)")
        }
    }
}

/// The top row's slim capsule: focus-pill thickness, 3 pt ends, so a lone button is a circle.
private struct SlimCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassCapsule(height: Tokens.Size.focusPillHeight, leading: 3, trailing: 3, spacing: 0) { content }
    }
}

/// Pages · ⋯ (top trailing). ⋯ holds the notebook's options under its title (paper, template, Keep exact
/// colors on Night paper), then Share and Focus mode. DEBUG adds a dock picker.
///
/// Compact chrome (#118): Add Photo and Laser Pointer join ⋯ (no room on the bar); focus mode (regular
/// chrome only) leaves it.
struct PagesCapsule: View {
    let tools: ToolState
    let state: EditorState
    let title: String
    /// Current page (1-based) and page count, for export.
    let page: (current: Int, total: Int)
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    /// "Keep exact colors", offered on Night paper.
    @Binding var keepsExactColors: Bool
    var isCompact = false

    @State private var showsShare = false
    @State private var showsPhotos = false
    @State private var presenter = ActivityPresenter()
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SlimCapsule {
            ToolButton(.pages, "Pages", size: Tokens.Size.focusToolButton) { state.pages.present() }
                .accessibilityHint("Shows all pages")
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
        let size = Tokens.Size.focusToolButton
        return Menu {
            Section(title) {
                Picker("Paper", systemImage: "doc", selection: $paper) {
                    ForEach(PaperTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                Picker("Template", systemImage: "squareshape.split.3x3", selection: $pattern) {
                    ForEach(PaperPattern.allCases) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
                .pickerStyle(.menu)
                if paper == .night {
                    Toggle("Keep exact colors", systemImage: "eyedropper", isOn: $keepsExactColors)
                }
            }
            Section {
                Button("Share", systemImage: Symbol.share.name) { showsShare = true }
                if isCompact {
                    Button("Add Photo", systemImage: Symbol.photo.name) { showsPhotos = true }
                    Toggle("Laser Pointer", systemImage: Symbol.laser.name, isOn: laserBinding)
                } else {
                    Button("Focus mode", systemImage: Symbol.focus.name) { state.enterFocus() }
                }
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
                .frame(width: size.width * scale, height: size.height * scale)
                .contentShape(.capsule)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityValue(title)
        .accessibilityHint("\(paper.displayName) paper, \(pattern.displayName). Share and notebook options")
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
        ChromeSeparator(axis: axis)
        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
            .disabled(!state.canUndo)
        if !isCompact {
            ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
                .disabled(!state.canRedo)
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

    /// A phone-width bar has no room for the laser pointer: it's in ⋯ (``PagesCapsule``).
    static let compactTools = Tool.allCases.filter { $0 != .laser }

    private func assign(_ index: Int) {
        tools.setQuickColor(tools.paletteColor, at: index)
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
