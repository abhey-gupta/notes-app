import Canvas
import UIKit

/// Two-finger tap undoes, three-finger tap redoes (#121). Always on, no toast:
/// the page changing is the feedback; VoiceOver hears what happened. A tap with nothing to undo or redo
/// does nothing.
@MainActor
final class TouchUndoGestures {
    private let state: EditorState
    private let taps = MultiFingerTaps()

    init(state: EditorState) {
        self.state = state
        taps.onTap = { [weak self] fingers in self?.tapped(fingers: fingers) }
    }

    /// Adds the taps to `host`'s canvas once.
    func install(on host: CanvasHostView) {
        taps.install(on: host)
    }

    private func tapped(fingers: Int) {
        switch fingers {
        case 2 where state.canUndo:
            state.undo()
            UIAccessibility.post(notification: .announcement, argument: "Undo")
        case 3 where state.canRedo:
            state.redo()
            UIAccessibility.post(notification: .announcement, argument: "Redo")
        default:
            break
        }
    }
}
