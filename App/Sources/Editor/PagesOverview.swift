import Canvas
import DesignSystem
import InkModel
import SwiftUI

/// Pages overview (mock §04, #32): a blurred overlay over the editor with every page as a thumbnail
/// (`thumbs/<id>.heic`, read lazily per visible cell, never rendered here), the current page ringed.
///
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
        ZStack(alignment: .bottom) {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            Rectangle().fill(Tokens.Colors.libraryBackground.color.opacity(0.55)).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                grid
            }
            if !isSelecting {
                TemplateCapsule(paper: paper) { style in
                    model.onInsert(currentIndex, style)
                }
                .padding(.bottom, Tokens.Spacing.xxl)
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
        .accessibilityAction(.escape) { isSelecting ? endSelecting() : model.dismiss() }
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
                onDone: model.dismiss
            )
        }
        .padding(.horizontal, Tokens.Spacing.libraryMargin)
        .padding(.top, Tokens.Spacing.xxl)
        .padding(.bottom, Tokens.Spacing.xl)
    }

    // MARK: Grid

    private var grid: some View {
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
        .scrollIndicators(.hidden)
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
            version: model.thumbnailVersion(entry.id)
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
        .zIndex(dragging ? 1 : 0)
        .animation(.snappy(duration: 0.18), value: dragging)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: { frames[index] = $0 }
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
            model.onShow(index)
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
