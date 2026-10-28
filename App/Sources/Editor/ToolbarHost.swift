import DesignSystem
import SwiftUI
import Tools

/// Editor chrome (mock §02): nav capsule, the dynamic tools toolbar, pages capsule, page pill, all in one
/// `GlassChrome` so every change of shape is a Liquid Glass morph (§7, #26).
///
/// The toolbar docks top (default), bottom, left or right. Drag it with a finger and it follows with an
/// interactive spring, rubber-banding at the screen edges, while a slot shows where it will land; release and
/// it springs to the nearest dock, re-flowing between horizontal and vertical in place. Pinch in to enter focus
/// mode (#158): the toolbar collapses to the compact pill at the same dock and the nav and pages capsules hide.
/// Focus mode lasts until the pill's chevron or a pinch out on the pill; drawing, scrolling and taps don't end
/// it. Dock persists in `ToolState`; focus mode doesn't.
///
/// Tapping the active tool on the expanded toolbar opens its options popover (``ToolPopover``, #27),
/// anchored to that button with the arrow toward the toolbar on every dock. The pill's tool and color are
/// display only; the pill has no popover.
struct ToolbarHost: View {
    let tools: ToolState
    let state: EditorState
    let title: String
    @Binding var paper: PaperTheme
    @Binding var pattern: PaperPattern
    let page: (current: Int, total: Int)
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var glass
    @State private var drag: Drag?
    @State private var pinch: CGFloat = 1
    @State private var metrics = Metrics()
    /// Tool whose options popover is open.
    @State private var options: Tool?
    /// Expanded tool buttons, in the capsule's coordinate space (popover anchors).
    @State private var toolFrames: [Tool: CGRect] = [:]

    enum ChromeID: Hashable {
        case nav, tools, pages
    }

    private struct Drag: Equatable {
        var offset: CGSize = .zero
        var target: ToolbarDock
    }

    /// Measured chrome geometry, in the chrome's own coordinate space (inside the horizontal inset).
    private struct Metrics: Equatable {
        var container: CGSize = .zero
        /// Toolbar frame at rest (not updated mid-drag).
        var tools: CGRect = .zero
        var nav: CGFloat = 0
        var pages: CGFloat = 0
        var pill: CGSize = .zero
        /// Expanded toolbar length along each axis, cached as each is seen (hint size, top-row fitting).
        var horizontalLength: CGFloat?
        var verticalLength: CGFloat?
    }

    private nonisolated static let space = "chrome"
    /// The tools capsule's own coordinate space.
    nonisolated static let capsuleSpace = "toolsCapsule"
    /// Fallback toolbar length before it has been measured on an axis.
    private static let estimatedLength: CGFloat = 400
    private static let estimatedPillLength: CGFloat = 140
    /// Pinching below this collapses on release.
    private static let collapseMagnification: CGFloat = 0.85
    /// Pinching the pill out past this expands it.
    private static let expandMagnification: CGFloat = 1.15
    /// Toolbar hit area: the capsule's bounding box plus a 2 pt rim, so a pinch whose fingers start on the
    /// capsule's rounded ends or outline still lands on the toolbar instead of inking the canvas.
    private static var hitShape: some Shape {
        Rectangle().inset(by: -2)
    }

    /// The toolbar is the compact pill exactly in focus mode (#158).
    private var isCompact: Bool {
        state.isFocused
    }

    var body: some View {
        GlassChrome {
            ZStack {
                if !state.isFocused {
                    HStack(alignment: .top) {
                        NavCapsule(title: title, paper: $paper, pattern: $pattern, keepsExactColors: exactColorsBinding, onBack: onBack)
                            .maxWidth(layout.navMaxWidth(at: tools.dock, toolbarLength: restingLength(.horizontal)))
                            .chromeID(.nav, in: glass, transition: glassTransition)
                            .onGeometryChange(for: CGFloat.self, of: \.size.width) { metrics.nav = $0 }
                            .accessibilitySortPriority(ChromeOrder.nav)
                        Spacer(minLength: Tokens.Spacing.m)
                        PagesCapsule(tools: tools, state: state, page: page, paper: paper)
                            .chromeID(.pages, in: glass, transition: glassTransition)
                            .onGeometryChange(for: CGFloat.self, of: \.size.width) { metrics.pages = $0 }
                            .accessibilitySortPriority(ChromeOrder.pages)
                    }
                    .padding(.top, Tokens.Spacing.s)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                if let drag {
                    dockHint(drag.target)
                }
                toolbar
                    .accessibilitySortPriority(ChromeOrder.tools)
                pagePill
                    .accessibilitySortPriority(ChromeOrder.pagePill)
            }
            // VoiceOver order, whatever the dock: nav, tools, pages, page pill (#45).
            .accessibilityElement(children: .contain)
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGSize.self, of: \.size) { metrics.container = $0 }
            .padding(.horizontal, Tokens.Spacing.chromeInset)
        }
        .animation(morphAnimation, value: isCompact)
        .animation(dockAnimation, value: tools.dock)
        .chromeGlass(for: paper)
    }

    private var ink: Color {
        tools.currentColor.color(on: paper)
    }

    private var glassTransition: GlassEffectTransition {
        reduceMotion ? .materialize : .matchedGeometry
    }

    /// Reduce Motion: focus mode and compact ⇄ expanded swap at once, no morph or fade (#45).
    private var morphAnimation: Animation? {
        reduceMotion ? nil : Tokens.Motion.morph
    }

    private var dockAnimation: Animation {
        reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.dock
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let dock = tools.dock
        let placement = layout.placement(for: dock, length: restingLength(dock.axis))
        return toolbarBody(axis: dock.axis)
            // Reduce Motion: a dock change swaps identity, so it crossfades instead of flying.
            .id(reduceMotion ? dock.rawValue : "toolbar")
            .transition(.opacity)
            .offset(drag?.offset ?? .zero)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { measured($0) }
            .padding(placement.insets)
            .offset(x: placement.shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dock.alignment)
    }

    /// One glass capsule for both states: expanded ⇄ compact resizes it (thickness, padding, length) while the
    /// contents cross-fade, so the glass itself morphs with the spring instead of swapping views. Glass doesn't
    /// follow `scaleEffect`, so pinch feedback squeezes the spacing instead and the capsule tracks it.
    private func toolbarBody(axis: Axis) -> some View {
        let compact = isCompact
        let ends = compact ? FocusPill.endPadding : Tokens.Spacing.s
        let squeeze = Tokens.Spacing.hairline - 40 * (1 - pinch)
        return GlassCapsule(
            axis: axis,
            height: compact ? Tokens.Size.focusPillHeight : Tokens.Size.capsuleHeight,
            leading: ends,
            trailing: ends,
            spacing: compact ? 0 : squeeze
        ) {
            if compact {
                pillContent(axis: axis)
                    .transition(contentTransition)
            } else {
                EditorToolbarContent(
                    tools: tools,
                    state: state,
                    paper: paper,
                    axis: axis, arrowEdge: optionsArrowEdge,
                    onReselect: toggleOptions,
                    onToolFrame: { toolFrames[$0] = $1 }
                )
                .transition(contentTransition)
            }
        }
        .coordinateSpace(.named(Self.capsuleSpace))
        .popover(
            isPresented: optionsPresented,
            attachmentAnchor: .rect(.rect(toolFrames[tools.tool] ?? .zero)),
            arrowEdge: optionsArrowEdge
        ) {
            ToolPopover(tools: tools, tool: options ?? tools.tool, paper: paper)
                .presentationCompactAdaptation(.popover)
                .dynamicTypeSize(...DynamicTypeSize.chromeLimit)
        }
        .onChange(of: state.toolOptionsRequests) {
            // Pencil "show palette/ink attributes" (#24): the expanded toolbar's popover; the pill has none.
            if !isCompact, tools.tool != .lasso {
                options = options == tools.tool ? nil : tools.tool
            }
        }
        .contentShape(Self.hitShape)
        .chromeID(.tools, in: glass, transition: glassTransition)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(compact ? "focusPill" : "toolbar")
        .accessibilityAction(named: compact ? "Show toolbar" : "Compact toolbar") {
            compact ? expand() : collapse()
        }
        .gesture(FingerPan(onBegan: dragBegan, onChanged: dragChanged, onEnded: dragEnded))
        .gesture(FingerPinch(onChanged: pinchChanged, onEnded: pinchEnded))
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.7))
    }

    private func measured(_ frame: CGRect) {
        guard drag == nil else { return }
        metrics.tools = frame
        guard !isCompact else { return }
        if tools.dock.isVertical {
            metrics.verticalLength = frame.height
        } else {
            metrics.horizontalLength = frame.width
        }
    }

    // MARK: Drag to dock

    private var bounds: CGRect {
        CGRect(origin: .zero, size: metrics.container)
    }

    private func dragBegan() {
        options = nil
        withAnimation(Tokens.Motion.dragFollow) {
            drag = Drag(target: tools.dock)
        }
    }

    private func dragChanged(_ translation: CGSize) {
        guard var next = drag else { return }
        // It may come within 6 pt of the screen edge (past the chrome inset), then resists for a further 24 pt.
        let reach = bounds.insetBy(dx: -(Tokens.Spacing.chromeInset - Tokens.Spacing.s), dy: 0)
        next.offset = DockGeometry.rubberBanded(translation, frame: metrics.tools, in: reach)
        next.target = DockGeometry.nearestDock(to: metrics.tools.center + translation, in: bounds, current: next.target)
        withAnimation(Tokens.Motion.dragFollow) {
            drag = next
        }
    }

    private func dragEnded(_ translation: CGSize, velocity: CGSize, cancelled: Bool) {
        guard drag != nil else { return }
        let projected = metrics.tools.center + translation + velocity * DockGeometry.flickProjection
        let target = cancelled ? tools.dock : DockGeometry.nearestDock(to: projected, in: bounds, current: tools.dock)
        withAnimation(dockAnimation) {
            tools.dock = target
            drag = nil
        }
    }

    // MARK: Pinch / compact

    /// The capsule shrinks with the fingers (damped), then morphs to the pill or springs back.
    private func pinchChanged(_ magnification: CGFloat) {
        options = nil
        guard !isCompact else { return }
        withAnimation(Tokens.Motion.dragFollow) {
            pinch = DockGeometry.pinchScale(magnification)
        }
    }

    /// Pinch in on the toolbar collapses it; pinch out on the pill expands it.
    private func pinchEnded(_ magnification: CGFloat) {
        if isCompact {
            if magnification > Self.expandMagnification {
                expand()
            }
        } else if magnification < Self.collapseMagnification {
            collapse()
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) {
                pinch = 1
            }
        }
    }

    private func collapse() {
        options = nil
        withAnimation(morphAnimation) {
            state.enterFocus()
            pinch = 1
        }
    }

    /// The pill's chevron or a pinch out on it: the only ways out of focus mode (#158).
    private func expand() {
        options = nil
        withAnimation(morphAnimation) {
            state.exitFocus()
        }
    }

    private var pagePill: some View {
        GlassPill.pageIndicator(current: page.current, total: page.total)
            .onGeometryChange(for: CGSize.self, of: \.size) { metrics.pill = $0 }
            .opacity(isCompact ? 0.7 : 1)
            .accessibilityIdentifier("pageIndicator")
            .accessibilityHint("Current page")
            .padding(.bottom, Tokens.Spacing.chromeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

extension ToolbarHost {
    // MARK: Tool options (#27)

    /// Expanded toolbar only: the pill never shows options.
    private var optionsPresented: Binding<Bool> {
        Binding {
            !isCompact && options != nil && options == tools.tool
        } set: { presented in
            if !presented {
                options = nil
            }
        }
    }

    private var exactColorsBinding: Binding<Bool> {
        Binding { state.keepsExactColors } set: { state.onKeepsExactColors($0) }
    }

    /// The compact pill: current tool and color (display only, named for VoiceOver), expand.
    private func pillContent(axis: Axis) -> some View {
        FocusPillContent(
            axis: axis, tool: tools.tool.symbol, ink: ink,
            toolName: tools.tool.label, colorName: tools.currentColor.accessibilityName,
            onExpand: expand
        )
    }

    /// Tap on the current tool: opens its options, or closes them if open. Lasso has none.
    private func toggleOptions(_ tool: Tool) {
        guard tool != .lasso else { return }
        options = options == tool ? nil : tool
    }

    /// `arrowEdge` is the popover's own edge carrying the arrow: the one facing the dock, so it opens away
    /// from the toolbar (below a top dock, beside a side dock).
    private var optionsArrowEdge: Edge {
        switch tools.dock {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

extension ToolbarHost {
    // MARK: Placement

    /// Length of the toolbar at rest on `axis` (compact or expanded).
    private func restingLength(_ axis: Axis) -> CGFloat {
        if isCompact {
            return Self.estimatedPillLength
        }
        let measured = axis == .horizontal ? metrics.horizontalLength : metrics.verticalLength
        return measured ?? metrics.horizontalLength ?? metrics.verticalLength ?? Self.estimatedLength
    }

    private var layout: DockLayout {
        DockLayout(
            containerWidth: metrics.container.width,
            nav: state.isFocused ? 0 : metrics.nav,
            pages: state.isFocused ? 0 : metrics.pages,
            pagePill: metrics.pill,
            isFocused: state.isFocused,
            scale: typeSize.chromeScale
        )
    }

    /// Drop slot at the drag target: the toolbar's footprint once docked there.
    private func dockHint(_ dock: ToolbarDock) -> some View {
        let length = restingLength(dock.axis)
        let thickness = (isCompact ? Tokens.Size.focusPillHeight : Tokens.Size.capsuleHeight) * typeSize.chromeScale
        let size = dock.isVertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
        let placement = layout.placement(for: dock, length: length)
        return Capsule()
            .fill(Tokens.Colors.dockHint)
            .overlay(Capsule().strokeBorder(Tokens.Colors.dockHintBorder, lineWidth: 1))
            .frame(width: size.width, height: size.height)
            .padding(placement.insets)
            .offset(x: placement.shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dock.alignment)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
    }
}
