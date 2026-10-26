import InkEngine
import InkModel
import PencilKit
import UIKit

/// Tool state on the canvases: pens map to PencilKit inking tools, eraser and lasso go to the input view.
extension PencilKitInkEngine {
    // MARK: Tool

    func applyTool() {
        input.allowsFingerDrawing = tool.allowsFingerDrawing
        input.isHidden = tool.penKind != nil
        if tool.tool != .eraser {
            hideEraserCursor()
        }
        for canvas in canvases {
            applyTool(to: canvas)
        }
    }

    func applyTool(to canvas: PageCanvas) {
        canvas.view.drawingPolicy = tool.allowsFingerDrawing && !hasSeenPencil ? .anyInput : .pencilOnly
        switch tool.tool {
        case let .pen(kind):
            canvas.view.tool = PencilKitConversion.inkingTool(kind, color: uiColor(tool.color), width: tool.width)
            canvas.view.isUserInteractionEnabled = true
        case .eraser, .lasso:
            canvas.view.isUserInteractionEnabled = false
        }
    }

    func pencilSeen() {
        guard !hasSeenPencil else { return }
        hasSeenPencil = true
        applyTool()
    }

    /// The stroke the current pen commits for `pk`, and the PencilKit stroke the canvas keeps for it. With
    /// pressure off (#123) both are flattened (``InkModel/Stroke/pressureFlattened``) and `canvas` is marked
    /// for a rebuild, which swaps the flattened stroke in once the tool lifts.
    func capture(_ pk: PKStroke, on canvas: PageCanvas) -> (Stroke, PKStroke) {
        let stroke = PencilKitConversion.stroke(from: pk, tool: tool.penKind ?? .ballpoint, color: tool.color, width: tool.width)
        guard !tool.pressure else { return (stroke, pk) }
        let flat = stroke.pressureFlattened
        canvas.needsRebuild = true
        return (flat, PencilKitConversion.pkStroke(from: flat, color: uiColor(tool.color)))
    }

    func uiColor(_ color: InkColor) -> UIColor {
        UIColor(palette.ink(color, on: theme))
    }
}
