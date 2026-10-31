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
/// - Bottom capsule: new page with that template after the current one (compact: a "New page" menu).
///
/// Compact (iPhone, #209): the header in two rows, two columns of smaller thumbs.
/// - Select: multi-select, Delete asks first only if a selected page has ink.
/// - Go to page (#214): type a number; the grid scrolls there and the page lifts with a fading halo.
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
    @State private var isJumping = false
    @State private var gridWidth: CGFloat = 0
    @State private var arrival = PageArrival()
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
                Group {
                    if chrome.isCompact {
                        TemplateMenuButton { style in model.onInsert(currentIndex, style) }
                    } else {
                        TemplateCapsule(paper: paper) { style in model.onInsert(currentIndex, style) }
                    }
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
        PagesOverviewHeader(
            title: title,
            count: model.entries.count,
            state: state,
            isSelecting: isSelecting,
            selectedCount: selected.count,
            isJumping: $isJumping,
            onJump: { index in
                arrival.jump(to: model.entries[index].id, number: index + 1, reduceMotion: reduceMotion)
            },
            onSelect: {
                isJumping = false
                isSelecting = true
            },
            onDelete: requestDelete,
            onCancel: endSelecting,
            onDone: { flight.close(to: nil, current: currentIndex, reduceMotion: reduceMotion) }
        )
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: layout.columns, alignment: .center, spacing: Tokens.Spacing.xxl) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        cell(entry, at: index)
                    }
                }
                .padding(.horizontal, chrome.margin)
                // Room for a first-row page's arrival halo (#214) inside the scroll view's clip.
                .padding(.top, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Size.templateCapsuleHeight + 2 * Tokens.Spacing.xxl)
            }
            .coordinateSpace(.named(Self.gridSpace))
            .scrollIndicators(.hidden)
            .scrollDisabled(drag != nil)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                flight.geometry.scroll = $0
                gridWidth = $0.width
            }
            .onAppear {
                arrival.proxy = proxy
                FrameAfter.next { flight.arrive(proxy, current: currentIndex, reduceMotion: reduceMotion) }
            }
            .onDisappear(perform: arrival.cancel)
            .onChange(of: layout, initial: true) { flight.geometry.layout = layout }
        }
    }

    private func cell(_ entry: PagesModel.Entry, at index: Int) -> some View {
        let dragging = drag?.index == index
        let isAnchor = index == flight.anchorIndex(current: currentIndex)
        let settled = isAnchor || flight.isOpen
        let arriving = arrival.page == entry.id
        let lifted = arriving && arrival.isLifted
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
            chromeAnimation: isAnchor ? segment(0.7, 1) : nil,
            halo: arriving ? (lifted ? 1 : 0.6) : 0,
            size: layout.thumb
        )
        .overlay(alignment: dropEdge(for: index)) { dropIndicator(index, dragging: dragging) }
        .scaleEffect(dragging ? 1.04 : lifted ? 1.06 : settled ? 1 : 0.96)
        .opacity(settled ? 1 : 0)
        .offset(dragging ? drag?.translation ?? .zero : .zero)
        .zIndex(dragging || arriving ? 1 : 0)
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

    @ViewBuilder
    private func dropIndicator(_ index: Int, dragging: Bool) -> some View {
        if drag?.target == index, !dragging {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Tokens.Colors.selection)
                .frame(width: Tokens.Size.pageThumbRing, height: layout.thumb.height)
                .offset(x: dropEdge(for: index) == .leading ? -layout.gap / 2 : layout.gap / 2)
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

extension PagesOverview {
    /// Coordinate space of the grid's content; `PageLift` reports locations in it.
    nonisolated static let gridSpace = "pagesGrid"
}

private extension PagesOverview {
    // MARK: Flight timing

    private func segment(_ from: Double, _ to: Double) -> Animation {
        FlightTiming.segment(from, to, opening: flight.isOpen, reduceMotion: reduceMotion)
    }

    private func rippleSegment(_ index: Int, anchor: Int) -> Animation {
        let delay = flight.rippleDelay(index: index, anchor: anchor)
        return segment(0.25 + delay, 0.85 + delay)
    }
}

private extension PagesOverview {
    struct Drag: Equatable {
        var index: Int
        var translation: CGSize = .zero
        var target: Int?
    }

    var layout: PagesGridLayout {
        PagesGridLayout(isCompact: chrome.isCompact, width: gridWidth, margin: chrome.margin)
    }
}
