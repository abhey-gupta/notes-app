import Canvas
import UIKit

extension NotebookSession {
    /// VoiceOver actions on the canvas's "Drawing area" (#45): undo and redo without hunting for the
    /// toolbar, and the pages overview.
    func installAccessibilityActions(on host: CanvasHostView) {
        host.drawingAccessibilityActions = [
            action("Undo") { $0.state.canUndo ? $0.state.undo() : nil },
            action("Redo") { $0.state.canRedo ? $0.state.redo() : nil },
            action("Show pages") { $0.state.pages.present() },
        ]
    }

    /// `perform` returns `nil` when there was nothing to do (VoiceOver plays its "can't" sound).
    private func action(_ name: String, _ perform: @escaping @MainActor (NotebookSession) -> Void?) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return perform(self) != nil
            }
        }
    }
}
