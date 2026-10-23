import PencilKit
import UIKit

/// Engine root view. Reports pen-down hit tests so the canvas can move to the touched page first.
@MainActor
final class HostView: UIView {
    var onHitTest: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches, self.point(inside: point, with: event) {
            onHitTest?(point)
        }
        return super.hitTest(point, with: event)
    }
}

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
