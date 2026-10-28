import InkEngine
import InkModel
import PencilKit
import UIKit

/// Tool state on the canvases: pens map to PencilKit inking tools; eraser, lasso, laser, the highlighter
/// (`+Highlighter`, #120) and pens with pressure off (`+FlatPen`, #123) go to the input view.
extension PencilKitInkEngine {
    // MARK: Tool

    /// The tool draws through the input view, not a PencilKit canvas.
    var drawsThroughInput: Bool {
        usesHighlighter || usesFlatPen
    }

    func applyTool() {
        input.allowsFingerDrawing = tool.allowsFingerDrawing
        input.recordsForce = tool.pressure
        input.isHidden = tool.penKind != nil && !drawsThroughInput
        if tool.tool != .eraser {
            hideEraserCursor()
        }
        if !usesLaser {
            laser.clear()
        }
        for canvas in canvases {
            applyTool(to: canvas)
        }
    }

    func applyTool(to canvas: PageCanvas) {
        canvas.view.drawingPolicy = tool.allowsFingerDrawing && !hasSeenPencil ? .anyInput : .pencilOnly
        switch tool.tool {
        case let .pen(kind) where !drawsThroughInput:
            canvas.view.tool = PencilKitConversion.inkingTool(kind, color: uiColor(tool.color), width: tool.width)
            canvas.view.isUserInteractionEnabled = true
        case .pen, .eraser, .lasso, .laser:
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
