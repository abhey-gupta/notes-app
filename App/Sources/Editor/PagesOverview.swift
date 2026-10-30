import Canvas
import DesignSystem
import InkModel
import SwiftUI
import UIKit

/// Pages overview (mock §04, #32): a blurred overlay over the editor with every page as a thumbnail
/// (`thumbs/<id>.heic`, read lazily per visible cell, never rendered here), the current page ringed.
///
/// - Tap a page: close and scroll the canvas to it.
/// - Long-press and drag a page onto another: move it there (one undo step).
/// - Bottom capsule: new page with that template after the current one.
/// - Select: multi-select, Delete asks first only if a selected page has ink.
///
/// Undo and redo sit in the header; ⌘Z and the three-finger gestures reach the same history.
///
/// Opening and closing are one spatial flight (#124, `PageFlightView`): the page as seen on the canvas
/// shrinks into its cell while the scrim, the other cells (rippling out from it), the header and the
/// capsule fade in on `FlightTiming` segments of the same 350 ms; closing plays it backwards, from
/// the tapped cell. The grid is scrolled to the current cell first (invisibly) when it starts off
/// screen; with Reduce Motion, or when a flight end is unavailable, everything crossfades instead.
struct PagesOverview: View {
    let model: PagesModel
    let state: EditorState
    let viewport: CanvasViewportState
    let title: String
    let paper: DesignSystem.PaperTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeLayout) private var chrome
    @State private var isSelecting = false
    @State private var selected: Set<PageID> = []
    @State private var confirmsDelete = false
    @State private var drag: Drag?
    @State private var flight: PagesFlight

    init(model: PagesModel, state: EditorState, viewport: CanvasViewportState, title: String, paper: DesignSystem.PaperTheme) {
        self.model = model
        self.state = state
        self.viewport = viewport
        self.title = title
        self.paper = paper
        _flight = State(initialValue: PagesFlight(model: model, paper: paper.paper.uiColor))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                Rectangle().fill(Tokens.Colors.libraryBackground.color.opacity(0.55)).ignoresSafeArea()
            }
            .opacity(flight.isOpen ? 1 : 0)
            .animation(segment(0, 0.6), value: flight.isOpen)
            VStack(spacing: 0) {
                header
                    .opacity(flight.isOpen ? 1 : 0)
                    .offset(y: flight.isOpen ? 0 : 6)
                    .animation(segment(0.4, 1), value: flight.isOpen)
                grid
            }
            if !isSelecting {
                TemplateCapsule(paper: paper) { style in
                    model.onInsert(currentIndex, style)
                }
                .padding(.bottom, Tokens.Spacing.xxl)
                .transition(.opacity)
                .opacity(flight.isOpen ? 1 : 0)
                .offset(y: flight.isOpen ? 0 : 6)
                .animation(segment(0.4, 1), value: flight.isOpen)
            }
            PageFlightHost(view: flight.view)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(Tokens.Motion.reducedMorph, value: isSelecting)
        .allowsHitTesting(!flight.isLeaving)
        .onChange(of: model.entries) { _, entries in
            let ids = Set(entries.map(\.id))
            selected = selected.filter(ids.contains)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteSelected)
        } message: {
            Text("Pages with ink are deleted too. You can undo this.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pagesOverview")
        // VoiceOver stays in the overlay; two-finger scrub leaves select mode, then the overview.
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { isSelecting ? endSelecting() : flight.close(
            to: nil,
            current: currentIndex,
            reduceMotion: reduceMotion
        ) }
        .accessibilityValue(model.openMilliseconds.map { String(format: "%.1f ms", $0) } ?? "")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pagesHeading)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(EditedLabel.pages(model.entries.count))
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("pagesCount")
            }
            Spacer(minLength: Tokens.Spacing.m)
            GlassCapsule(height: Tokens.Size.focusPillHeight, leading: Tokens.Spacing.xs, trailing: Tokens.Spacing.xs) {
                ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
                    .disabled(!state.canUndo)
                ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
                    .disabled(!state.canRedo)
            }
            OverviewHeaderButtons(
                isSelecting: isSelecting,
                selectedCount: selected.count,
                canDelete: !selected.isEmpty && selected.count < model.entries.count,
                onSelect: { isSelecting = true },
                onDelete: requestDelete,
                onCancel: endSelecting,
                onDone: { flight.close(to: nil, current: currentIndex, reduceMotion: reduceMotion) }
            )
        }
        // Clear of an iPadOS window's controls (#118).
        .padding(.leading, chrome.margin + chrome.windowControls.leading)
        .padding(.trailing, chrome.margin)
        .padding(.top, Tokens.Spacing.xxl)
        .padding(.bottom, Tokens.Spacing.xl)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .center, spacing: Tokens.Spacing.xxl) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        cell(entry, at: index)
                    }
                }
                .padding(.horizontal, chrome.margin)
                .padding(.top, Tokens.Spacing.s)
                .padding(.bottom, Tokens.Size.templateCapsuleHeight + 2 * Tokens.Spacing.xxl)
            }
            .coordinateSpace(.named(Self.gridSpace))
            .scrollIndicators(.hidden)
            .scrollDisabled(drag != nil)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { flight.geometry.scroll = $0 }
            .onAppear {
                FrameAfter.next { flight.arrive(proxy, current: currentIndex, reduceMotion: reduceMotion) }
            }
        }
    }

    private func cell(_ entry: PagesModel.Entry, at index: Int) -> some View {
        let dragging = drag?.index == index
        let isAnchor = index == flight.anchorIndex(current: currentIndex)
        let settled = isAnchor || flight.isOpen
        return PageThumb(
            entry: entry,
            number: index + 1,
            total: model.entries.count,
            isCurrent: index == currentIndex,
            isSelecting: isSelecting,
            isSelected: selected.contains(entry.id),
            paper: paper,
            version: model.thumbnailVersion(entry.id),
            showsContent: !(isAnchor && flight.hidesAnchorContent),
            showsChrome: !isAnchor || flight.isOpen,
            chromeAnimation: isAnchor ? segment(0.7, 1) : nil
        )
        .overlay(alignment: dropEdge(for: index)) {
            if drag?.target == index, !dragging {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Tokens.Colors.selection)
                    .frame(width: Tokens.Size.pageThumbRing, height: Tokens.Size.pageThumb.height)
                    .offset(x: dropEdge(for: index) == .leading ? -Tokens.Size.pageThumbGap / 2 : Tokens.Size.pageThumbGap / 2)
            }
        }
        .scaleEffect(dragging ? 1.04 : settled ? 1 : 0.96)
        .opacity(settled ? 1 : 0)
        .offset(dragging ? drag?.translation ?? .zero : .zero)
        .zIndex(dragging ? 1 : 0)
        .animation(.snappy(duration: 0.18), value: dragging)
        .animation(isAnchor ? nil : rippleSegment(index, anchor: flight.anchorIndex(current: currentIndex)), value: flight.isOpen)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: { flight.geometry.cells[index] = $0 }
        .onAppear { model.onCellAppear(entry.id) }
        .onDisappear {
            flight.geometry.cells[index] = nil
            model.onCellDisappear(entry.id)
        }
        .onTapGesture { tapped(entry, at: index) }
        .accessibilityAction { tapped(entry, at: index) }
        .gesture(PageLift(isEnabled: !isSelecting) { phase in reorder(index, phase) })
        .accessibilityActions {
            if index > 0 {
                Button("Move earlier") { model.onMove(index, index - 1) }
            }
            if index < model.entries.count - 1 {
                Button("Move later") { model.onMove(index, index + 1) }
            }
        }
    }

    /// Where the drop indicator sits on the target cell: before it when moving up, after it when moving down.
    private func dropEdge(for index: Int) -> Alignment {
        guard let drag else { return .leading }
        return index > drag.index ? .trailing : .leading
    }

    var currentIndex: Int {
        min(viewport.currentPage, max(model.entries.count - 1, 0))
    }

    // MARK: Flight timing

    private func segment(_ from: Double, _ to: Double) -> Animation {
        FlightTiming.segment(from, to, opening: flight.isOpen, reduceMotion: reduceMotion)
    }

    private func rippleSegment(_ index: Int, anchor: Int) -> Animation {
        let delay = flight.rippleDelay(index: index, anchor: anchor)
        return segment(0.25 + delay, 0.85 + delay)
    }

    // MARK: Actions

    private func tapped(_ entry: PagesModel.Entry, at index: Int) {
        if isSelecting {
            if selected.remove(entry.id) == nil {
                selected.insert(entry.id)
            }
        } else {
            flight.close(to: index, current: currentIndex, reduceMotion: reduceMotion)
        }
    }

    /// Long-press lifts the page; drag it over another page and release to move it there.
    private func reorder(_ index: Int, _ phase: PageLift.Phase) {
        switch phase {
        case .lifted:
            drag = Drag(index: index)
        case let .moved(translation, location):
            drag = Drag(index: index, translation: translation, target: target(at: location, from: index))
        case let .dropped(location):
            defer { drag = nil }
            guard let target = target(at: location, from: index), target != index else { return }
            model.onMove(index, target)
        case .cancelled:
            drag = nil
        }
    }

    /// The visible cell under `point`, if any other than the dragged one.
    private func target(at point: CGPoint, from index: Int) -> Int? {
        flight.geometry.cells.first { $0.key != index && $0.key < model.entries.count && $0.value.contains(point) }?.key
    }

    private func requestDelete() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        Task {
            if await model.hasInk(ids) {
                confirmsDelete = true
            } else {
                deleteSelected()
            }
        }
    }

    private func deleteSelected() {
        model.onDelete(selectedIDs)
        endSelecting()
    }

    /// Selected pages in page order.
    private var selectedIDs: [PageID] {
        model.entries.map(\.id).filter(selected.contains)
    }

    private var deleteTitle: String {
        selected.count == 1 ? "Delete this page?" : "Delete \(selected.count) pages?"
    }

    private func endSelecting() {
        isSelecting = false
        selected = []
    }
}

private extension PagesOverview {
    struct Drag: Equatable {
        var index: Int
        var translation: CGSize = .zero
        var target: Int?
    }

    nonisolated static let gridSpace = "pagesGrid"
    static let columns = [
        GridItem(
            .adaptive(minimum: Tokens.Size.pageThumb.width, maximum: Tokens.Size.pageThumb.width),
            spacing: Tokens.Size.pageThumbGap, alignment: .top
        ),
    ]
}

/// Long-press-then-drag on a page cell, in the grid's coordinate space (#197).
///
/// UIKit-backed: a SwiftUI `LongPressGesture` sequenced before a zero-distance `DragGesture` claims the
/// touch from the start, so a swipe that began on a page never scrolled the grid. A long press fails
/// once the finger travels 10 pt before 0.3 s, which leaves the swipe to the scroll view.
struct PageLift: UIGestureRecognizerRepresentable {
    enum Phase {
        case lifted
        /// Translation since the lift, finger location.
        case moved(CGSize, CGPoint)
        case dropped(CGPoint)
        case cancelled
    }

    var isEnabled = true
    var onPhase: (Phase) -> Void

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context _: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.3
        return press
    }

    func updateUIGestureRecognizer(_ press: UILongPressGestureRecognizer, context _: Context) {
        press.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .named(PagesOverview.gridSpace))
        switch press.state {
        case .began:
            context.coordinator.start = location
            onPhase(.lifted)
        case .changed:
            let start = context.coordinator.start
            onPhase(.moved(CGSize(width: location.x - start.x, height: location.y - start.y), location))
        case .ended:
            onPhase(.dropped(location))
        case .cancelled, .failed:
            onPhase(.cancelled)
        default:
            break
        }
    }

    final class Coordinator {
        var start = CGPoint.zero
    }
}
