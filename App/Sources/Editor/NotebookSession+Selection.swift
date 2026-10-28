import Canvas
import DesignSystem
import Editing
import InkEngine
import InkModel
import Tools
import UIKit

/// Lasso selection (ARCHITECTURE.md §6, #29): `SelectionMachine` owns it; the session wires its inputs
/// and is its display.
///
/// ```
/// lasso path ─▶ SelectionMachine ─▶ overlay (hull, handles) + context bar
/// drag ─▶ engine.setSelectionPreview (lifted image, transform per frame) ─release─▶ PageEdit.transform
/// bar ─▶ recolor / duplicate (+20 pt) / delete ─▶ PageEdit.recolor / .add(Images) / .remove(Images)
/// photo flyout ─▶ SelectionMachine.insert ─▶ PageEdit.addImages, then selected (`+Photos`, #157)
/// ```
///
/// Every action goes through the `EditPipeline` like a stroke, then the selection is rebuilt from the page.
/// A new gesture, a tool change, undo/redo, a tap outside or the page scrolling away clears it.
extension NotebookSession: SelectionDisplay {
    func installSelection(on host: CanvasHostView, engine: any InkEngine, theme: InkModel.PaperTheme) {
        let overlay = selectionOverlay
        overlay.onDragBegan = { [weak self] corner in self?.selectionDragBegan(corner) ?? false }
        overlay.onDrag = { [weak self] phase, transform in self?.selectionDragged(phase, transform) }
        overlay.onFrameChange = { [weak self] frame in self?.state.selectionFrame = frame }
        overlay.onTapOutside = { [weak self] in self?.clearSelection() }
        host.overlay = overlay
        tintSelection(for: theme, engine: engine)
    }

    /// Selection outline in the selection token for the paper (its dark value on Night).
    func tintSelection(for theme: InkModel.PaperTheme, engine: (any InkEngine)? = nil) {
        let token = Tokens.Colors.selection
        let color = (theme == .night ? token.dark : token.light).uiColor
        selectionOverlay.tint = color
        (engine ?? self.engine).selectionColor = color
    }

    func clearSelection() {
        selection?.clear()
    }

    func performSelectionAction(_ action: SelectionAction) {
        switch action {
        case let .recolor(color): selection?.recolor(to: color)
        case .duplicate: selection?.duplicate()
        case .delete: selection?.delete()
        }
    }

    // MARK: SelectionDisplay

    func showSelection(_ selection: LassoSelection?) {
        selectionOverlay.selection = selection
        state.selectionHasInk = selection?.hasInk ?? true
        // Render the drag preview now (off main), not when the drag starts.
        engine.prepareSelectionPreview(Set(selection?.strokeIDs ?? []), on: selection?.pageID ?? PageID())
    }

    func liftSelection(_ selection: LassoSelection?, transform: CGAffineTransform) {
        engine.setSelectionPreview(selection.map {
            SelectionPreview(page: $0.pageID, strokes: Set($0.strokeIDs), images: Set($0.imageIDs), transform: transform)
        })
    }

    // MARK: Drag

    private func selectionDragBegan(_ corner: LassoSelection.Corner?) -> Bool {
        selection?.beginDrag(from: corner) == true
    }

    private func selectionDragged(_ phase: SelectionOverlayView.DragPhase, _ transform: CGAffineTransform) {
        switch phase {
        case .changed: selection?.drag(transform)
        case .cancelled: selection?.cancelDrag()
        case .ended: selection?.endDrag(transform)
        }
    }
}
