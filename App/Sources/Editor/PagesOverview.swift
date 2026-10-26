import Canvas
import DesignSystem
import InkModel
import SwiftUI

/// Pages overview (mock §04, #32): a blurred overlay over the editor with every page as a thumbnail
/// (`thumbs/<id>.heic`, read lazily per visible cell, never rendered here), the current page ringed.
///
/// - Open: the canvas page zooms down into its cell while the rest fades in; closing reverses it, and a
///   tapped page grows into the canvas (#124). Reduce Motion crossfades instead.
/// - Tap a page: close and scroll the canvas to it.
/// - Long-press and drag a page onto another: move it there (one undo step).
/// - Bottom capsule: new page with that template after the current one.
/// - Select: multi-select, Delete asks first only if a selected page has ink.
///
/// Undo and redo sit in the header; ⌘Z and the three-finger gestures reach the same history.
struct PagesOverview: View {
    let model: PagesModel
    let state: EditorState
    let viewport: CanvasViewportState
    let title: String
    let paper: DesignSystem.PaperTheme

    @State private var isSelecting = false
    @State private var selected: Set<PageID> = []
    @State private var confirmsDelete = false
    @State private var drag: Drag?
    /// Visible cells' frames in ``gridSpace`` (drop targets).
    @State private var frames: [Int: CGRect] = [:]
    /// ``gridSpace``'s origin in window points (cell frames → the canvas page's space).
    @State private var gridOrigin: CGPoint = .zero
    /// Open/close zoom: settled = grid shown; otherwise the ``flight`` cell sits on ``pageFrame``.
    @State private var isSettled = false
    @State private var isClosing = false
    @State private var flight: Int?
    @State private var pageFrame: CGRect?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Drag: Equatable {
        var index: Int
        var translation: CGSize = .zero
        var target: Int?
    }

    private nonisolated static let gridSpace = "pagesGrid"
    private static let columns = [
        GridItem(
            .adaptive(minimum: Tokens.Size.pageThumb.width, maximum: Tokens.Size.pageThumb.width),
            spacing: Tokens.Size.pageThumbGap, alignment: .top
        ),
    ]

    var body: some View {
        let settled = isSettled || reduceMotion
        ZStack(alignment: .bottom) {
            Group {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Tokens.Colors.libraryBackground.color.opacity(0.55))
            }
            .ignoresSafeArea()
            .opacity(settled ? 1 : 0)
            VStack(spacing: 0) {
                header
                    .opacity(settled ? 1 : 0)
                grid
            }
            if !isSelecting {
                TemplateCapsule(paper: paper) { style in
                    model.onInsert(currentIndex, style)
                }
                .padding(.bottom, Tokens.Spacing.xxl)
                .opacity(settled ? 1 : 0)
                .transition(.opacity)
            }
        }
        .animation(Tokens.Motion.reducedMorph, value: isSelecting)
        .onAppear {
            FrameAfter.next { model.didRenderFirstFrame() }
        }
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
        .accessibilityAction(.escape) { isSelecting ? endSelecting() : close() }
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
                onDone: { close() }
            )
        }
        .padding(.horizontal, Tokens.Spacing.libraryMargin)
        .padding(.top, Tokens.Spacing.xxl)
        .padding(.bottom, Tokens.Spacing.xl)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Tokens.Spacing.xxl) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        cell(entry, at: index)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.libraryMargin)
                .padding(.top, Tokens.Spacing.s)
                .padding(.bottom, Tokens.Size.templateCapsuleHeight + 2 * Tokens.Spacing.xxl)
            }
            .coordinateSpace(.named(Self.gridSpace))
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { gridOrigin = $0 }
            .scrollIndicators(.hidden)
            // The flying page is drawn past the grid's edges.
            .scrollClipDisabled(flight != nil)
            .onAppear { open(proxy) }
        }
    }

    private func cell(_ entry: PagesModel.Entry, at index: Int) -> some View {
        let dragging = drag?.index == index
        return PageThumb(
            entry: entry,
            number: index + 1,
            total: model.entries.count,
            isCurrent: index == currentIndex,
            isSelecting: isSelecting,
            isSelected: selected.contains(entry.id),
            paper: paper,
            version: model.thumbnailVersion(entry.id),
            isFlying: flight == index && !isSettled
        )
        .overlay(alignment: dropEdge(for: index)) {
            if drag?.target == index, !dragging {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Tokens.Colors.selection)
                    .frame(width: Tokens.Size.pageThumbRing, height: Tokens.Size.pageThumb.height)
                    .offset(x: dropEdge(for: index) == .leading ? -Tokens.Size.pageThumbGap / 2 : Tokens.Size.pageThumbGap / 2)
            }
        }
        .scaleEffect(dragging ? 1.04 : 1)
        .offset(dragging ? drag?.translation ?? .zero : .zero)
        .zIndex(dragging || flight == index ? 1 : 0)
        .animation(.snappy(duration: 0.18), value: dragging)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: { frames[index] = $0 }
        .modifier(zoom(for: index))
        .onTapGesture { tapped(entry, at: index) }
        .accessibilityAction { tapped(entry, at: index) }
        .gesture(isSelecting ? nil : reorderGesture(from: index))
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

    private var currentIndex: Int {
        min(viewport.currentPage, max(model.entries.count - 1, 0))
    }

    // MARK: Actions

    private func tapped(_ entry: PagesModel.Entry, at index: Int) {
        if isSelecting {
            if selected.remove(entry.id) == nil {
                selected.insert(entry.id)
            }
        } else {
            close(showing: index)
        }
    }

    /// Long-press lifts the page; drag it over another page and release to move it there.
    private func reorderGesture(from index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    drag = Drag(index: index)
                case let .second(true, gesture?):
                    drag = Drag(index: index, translation: gesture.translation, target: target(at: gesture.location, from: index))
                default:
                    break
                }
            }
            .onEnded { value in
                defer { drag = nil }
                guard case let .second(true, gesture?) = value,
                      let target = target(at: gesture.location, from: index), target != index else { return }
                model.onMove(index, target)
            }
    }

    /// The visible cell under `point`, if any other than the dragged one.
    private func target(at point: CGPoint, from index: Int) -> Int? {
        frames.first { $0.key != index && $0.key < model.entries.count && $0.value.contains(point) }?.key
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

// MARK: - Open / close (#124)

extension PagesOverview {
    /// Unsettled: the flight cell's paper covers the canvas page, the others wait faded and slightly small.
    private func zoom(for index: Int) -> CellZoom {
        guard !isSettled, !reduceMotion else { return CellZoom() }
        guard flight == index, let page = pageFrame, let cell = frames[index] else { return CellZoom(opacity: 0, scale: 0.96) }
        let paper = Tokens.Size.pageThumb
        return CellZoom(
            scaleX: page.width / paper.width,
            scaleY: page.height / paper.height,
            offset: CGSize(width: page.minX - gridOrigin.x - cell.minX, height: page.minY - gridOrigin.y - cell.minY)
        )
    }

    /// Brings the current cell into view, starts it on the canvas page, then zooms it down a frame later.
    private func open(_ proxy: ScrollViewProxy) {
        guard !reduceMotion, model.entries.indices.contains(currentIndex) else { return }
        flight = currentIndex
        pageFrame = model.pageFrame(currentIndex)
        proxy.scrollTo(model.entries[currentIndex].id, anchor: .center)
        FrameAfter.next {
            withAnimation(Tokens.Motion.pageZoom) {
                isSettled = true
            } completion: {
                if isSettled {
                    flight = nil
                }
            }
        }
    }

    /// Zooms the page at `index` (the current one if `nil`) back up onto the canvas, then dismisses;
    /// a tapped page is scrolled to first so it lands where it will stay.
    private func close(showing index: Int? = nil) {
        guard !isClosing else { return }
        let target = index ?? currentIndex
        guard !reduceMotion else {
            if let index {
                model.onShow(index)
            } else {
                model.dismiss()
            }
            return
        }
        if let index {
            model.onScroll(index)
        }
        isClosing = true
        flight = target
        pageFrame = model.pageFrame(target)
        withAnimation(Tokens.Motion.pageZoom) {
            isSettled = false
        } completion: {
            model.dismiss()
        }
    }
}

/// A cell's part in the open/close zoom; the default is the settled grid.
private struct CellZoom: ViewModifier {
    var opacity: Double = 1
    var scale: CGFloat = 1
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var offset: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
            .offset(offset)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}
