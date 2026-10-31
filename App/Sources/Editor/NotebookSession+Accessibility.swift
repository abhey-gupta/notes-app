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

    /// "12 strokes" for the page under the indicator (VoiceOver, UI tests); with ghost ink (#225), "12 strokes,
    /// replaced version in blue: 9 strokes".
    func currentPageDescription() -> String? {
        let index = host.state.currentPage
        guard let residency, residency.pageIDs.indices.contains(index), let page = residency.page(residency.pageIDs[index]) else {
            return nil
        }
        let strokes = Self.strokes(page.strokes.count)
        guard let ghost = ghosts[page.id] else { return strokes }
        return "\(strokes), replaced version in blue: \(Self.strokes(ghost.count))"
    }

    private static func strokes(_ count: Int) -> String {
        count == 1 ? "1 stroke" : "\(count) strokes"
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
