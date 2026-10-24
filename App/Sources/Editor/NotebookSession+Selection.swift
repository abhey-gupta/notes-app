import Canvas
import DesignSystem
import InkEngine
import InkEnginePencilKit
import InkModel
import Tools
import UIKit

/// Lasso selection (ARCHITECTURE.md §6, #29): resolve → overlay → one `PageEdit` per action.
///
/// ```
/// lasso path ─▶ LassoSelection(lasso:on:) ─▶ overlay (hull, handles) + context bar
/// drag ─▶ engine.setSelectionPreview (lifted image, transform per frame) ─release─▶ PageEdit.transform
/// bar ─▶ recolor / duplicate (+20 pt) / delete ─▶ PageEdit.recolor / .add / .remove
/// ```
///
/// Every action goes through the edit queue like a stroke (store, then mirror + engine, then one
/// `EditStack` entry), then the selection is rebuilt from the page. A new gesture, a tool change,
/// undo/redo, a tap outside or the page scrolling away clears it.
extension NotebookSession {
    func installSelection(on host: CanvasHostView, engine: PencilKitInkEngine, theme: InkModel.PaperTheme) {
        let overlay = selectionOverlay
        overlay.onDragBegan = { [weak self] corner in self?.selectionDragBegan(corner) ?? false }
        overlay.onDrag = { [weak self] phase, transform in self?.selectionDragged(phase, transform) }
        overlay.onFrameChange = { [weak self] frame in self?.state.selectionFrame = frame }
        overlay.onTapOutside = { [weak self] in self?.clearSelection() }
        host.overlay = overlay
        tintSelection(for: theme, engine: engine)
    }

    /// Selection outline in the selection token for the paper (its dark value on Night).
    func tintSelection(for theme: InkModel.PaperTheme, engine: PencilKitInkEngine? = nil) {
        let token = Tokens.Colors.selection
        let color = (theme == .night ? token.dark : token.light).uiColor
        selectionOverlay.tint = color
        (engine ?? (self.engine as? PencilKitInkEngine))?.selectionColor = color
    }

    func select(lasso path: [CGPoint], on page: PageID) {
        enqueue("lasso") { [weak self] in
            guard let self, let residency else { return }
            let resolved = try await LassoSelection(lasso: path, on: residency.ensureLoaded(page))
            show(resolved)
        }
    }

    func clearSelection() {
        guard selection != nil else { return }
        show(nil)
        if !isBakingSelection {
            engine.setSelectionPreview(nil)
        }
    }

    func performSelectionAction(_ action: SelectionAction) {
        switch action {
        case let .recolor(color):
            editSelection("Recolor") { selection, page in
                try selection.recolorEdit(to: color, on: page).map { ($0, selection) }
            }
        case .duplicate:
            editSelection("Duplicate") { selection, page in
                selection.duplicateEdit(on: page).map { ($0.edit, $0.selection) }
            }
        case .delete:
            editSelection("Delete") { selection, page in
                try (selection.removeEdit(on: page), nil)
            }
        }
    }

    // MARK: Drag

    private func selectionDragBegan(_ corner: LassoSelection.Corner?) -> Bool {
        guard let selection, !isBakingSelection else { return false }
        state.exitFocus()
        engine.setSelectionPreview(SelectionPreview(page: selection.pageID, strokes: Set(selection.strokeIDs)))
        selectionDragCorner = corner
        return true
    }

    private func selectionDragged(_ phase: SelectionOverlayView.DragPhase, _ transform: CGAffineTransform) {
        guard let selection else { return }
        let preview = SelectionPreview(page: selection.pageID, strokes: Set(selection.strokeIDs), transform: transform)
        switch phase {
        case .changed:
            engine.setSelectionPreview(preview)
        case .cancelled:
            engine.setSelectionPreview(nil)
        case .ended:
            guard !transform.isIdentity else {
                engine.setSelectionPreview(nil)
                return
            }
            engine.setSelectionPreview(preview)
            // One baked transform for the whole drag = one undo step. The lifted image stays at the drop
            // point until the edit has reached the engine, then the canvas draws the strokes there.
            isBakingSelection = true
            editSelection(
                selectionDragCorner == nil ? "Move" : "Resize",
                completion: { [weak self] in
                    guard let self else { return }
                    isBakingSelection = false
                    engine.setSelectionPreview(nil)
                },
                make: { selection, page in try selection.transformEdit(transform, on: page).map { ($0, selection) } }
            )
        }
    }

    // MARK: Edits

    /// Runs one selection action as one edit (one undo step) on the edit queue, then shows the selection
    /// `make` returns, rebuilt from the edited page (`nil` = none). `make` returning `nil` = nothing to do.
    private func editSelection(
        _ name: String,
        completion: (@MainActor () -> Void)? = nil,
        make: @escaping @MainActor (LassoSelection, Page) throws -> (PageEdit, LassoSelection?)?
    ) {
        guard let selection else {
            completion?()
            return
        }
        enqueue("selection") { [weak self] in
            defer { completion?() }
            guard let self, let residency else { return }
            let page = try await residency.ensureLoaded(selection.pageID)
            guard let result = try make(selection, page) else { return }
            let (edit, next) = result
            try await commit(edit, to: selection.pageID)
            state.edits.record(edit, on: selection.pageID, actionName: name)
            // Cleared meanwhile (tool change, new lasso)? Then stay cleared.
            guard self.selection?.strokeIDs == selection.strokeIDs else { return }
            show(next.flatMap { next in residency.page(selection.pageID).flatMap { LassoSelection(next.strokeIDs, on: $0) } })
        }
    }

    private func show(_ selection: LassoSelection?) {
        self.selection = selection
        selectionOverlay.selection = selection
        // Render the drag preview now (off main), not when the drag starts.
        engine.prepareSelectionPreview(Set(selection?.strokeIDs ?? []), on: selection?.pageID ?? PageID())
    }
}
