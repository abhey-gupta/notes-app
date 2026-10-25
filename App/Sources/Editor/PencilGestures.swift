import Tools
import UIKit

/// Apple Pencil double-tap and squeeze (#24, §3.2), honoring the system's preferred actions (Settings →
/// Apple Pencil; "Off" is `.ignore`). Hover needs nothing here: PencilKit's canvases draw the tool preview
/// themselves when the system's hover setting is on.
@MainActor
final class PencilGestures: NSObject, UIPencilInteractionDelegate {
    private let tools: ToolState
    private let state: EditorState
    private weak var view: UIView?

    init(tools: ToolState, state: EditorState) {
        self.tools = tools
        self.state = state
    }

    /// Adds the interaction to `view` once.
    func install(on view: UIView) {
        guard self.view !== view else { return }
        self.view = view
        view.addInteraction(UIPencilInteraction(delegate: self))
    }

    func pencilInteraction(_: UIPencilInteraction, didReceiveTap _: UIPencilInteraction.Tap) {
        perform(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteraction(_: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        perform(UIPencilInteraction.preferredSqueezeAction)
    }

    private func perform(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser:
            tools.toggleEraser()
        case .switchPrevious:
            tools.switchToPrevious()
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            state.requestToolOptions()
        default:
            // .ignore (system setting Off), .runSystemShortcut (the system runs it), future cases.
            break
        }
    }
}
