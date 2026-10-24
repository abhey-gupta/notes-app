import PencilKit
import UIKit

/// Engine root view: content-sized, inside the host's zoom view (ARCHITECTURE.md §3, Zoom). Draws
/// nothing itself, so its size costs no memory.
@MainActor
final class HostView: UIView {}

/// `PKCanvasView` with PencilKit's undo disabled (undo belongs to `Tools`) and a Pencil sighting hook.
@MainActor
final class AdapterCanvasView: PKCanvasView {
    var onPencilTouch: (() -> Void)?
    private let inertUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? {
        inertUndoManager
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .pencil }) {
            onPencilTouch?()
        }
        super.touchesBegan(touches, with: event)
    }
}
