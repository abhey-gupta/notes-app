import Canvas
import CoreGraphics
import InkEngine
import InkModel

// MARK: - Engine

extension NotebookSession: InkEngineDelegate {
    func engine(_: any InkEngine, didCommit pieces: [(page: PageID, stroke: Stroke)]) {
        edits?.commitStroke(pieces)
    }

    /// Each batch is applied at once (stroke mode removes the strokes it touched, partial mode splits them,
    /// highlighter included); at gesture end ``EditPipeline`` collapses the batches into one undo step.
    func engine(_: any InkEngine, didReceiveEraser samples: [Sample], to page: PageID) {
        guard case let .eraser(eraser) = tool else { return }
        edits?.erase(samples, on: page, diameter: eraser.width, mode: eraser.mode)
    }

    /// A finished lasso: strokes with ≥ 50 % of their samples inside become the selection (`+Selection`).
    func engine(_: any InkEngine, didReceiveLasso path: [CGPoint], to page: PageID) {
        selection?.lassoClosed(path, on: page)
    }

    func engineDidBeginStroke(_: any InkEngine) {
        clearSelection()
        if !host.isFirstResponder {
            host.becomeFirstResponder()
        }
        isErasing = tool.isEraser
        edits?.beginGesture(erasing: isErasing)
    }
}

// MARK: - Canvas

extension NotebookSession: CanvasHostViewDelegate {
    func canvasHost(_: CanvasHostView, didChange window: PageWindow) {
        residency?.update(window)
        if let selected = selection?.selection, residency?.isVisible(selected.pageID) != true {
            clearSelection()
        }
    }

    func canvasHostDidRequestNewPage(_: CanvasHostView) {
        insertPage(after: nil, template: nil)
    }

    func canvasHostDidRequestUndo(_: CanvasHostView) {
        state.undo()
    }

    func canvasHostDidRequestRedo(_: CanvasHostView) {
        state.redo()
    }

    func canvasHostDidBeginTouch(_: CanvasHostView) {
        state.collapseTabs()
        state.onTouch()
    }

    func canvasHostDidLiftAllTouches(_: CanvasHostView) {
        edits?.endGesture()
        if isErasing {
            isErasing = false
            onErased?()
        }
    }
}
