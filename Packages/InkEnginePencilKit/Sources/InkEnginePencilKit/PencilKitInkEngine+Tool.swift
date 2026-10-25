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

    func uiColor(_ color: InkColor) -> UIColor {
        UIColor(palette.ink(color, on: theme))
    }
}
