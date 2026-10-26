import InkEngine
import InkGeometry
import InkModel
import PencilKit
import UIKit

/// Pens with pressure off (#123). PencilKit sizes live points from the Pencil's force itself and can't be
/// told not to (its one force-blind ink, monoline, stops at 4 pt), so these strokes bypass the canvases:
/// the shared `InkInputView` records them at neutral force, a constant-width line on the selection view
/// shows them under the Pencil, and on lift the stroke is committed with one point size throughout (the
/// size the pen's ink draws at neutral force, as the popover preview shows it) and appended to the canvas
/// as that PencilKit stroke, so re-rendering it never shapes it by pressure or tilt.
extension PencilKitInkEngine {
    /// The current tool is a pen with pressure off: input and drawing go through this path.
    var usesFlatPen: Bool {
        tool.penKind != nil && !tool.pressure
    }

    func setUpFlatPen() {
        selection.flatPen.fillColor = nil
        selection.flatPen.lineCap = .round
        selection.flatPen.lineJoin = .round
        selection.view.layer.insertSublayer(selection.flatPen, at: 0)
    }

    /// Draws the live stroke; commits it on lift.
    func drawFlatPen(_ event: InkInputTracker.Event) {
        guard let kind = tool.penKind else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch event {
        case let .began(stroke), let .updated(stroke):
            let pageToContent = stroke.viewToPage.inverted()
            let path = CGMutablePath()
            path.addLines(between: stroke.displaySamples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)).applying(pageToContent) })
            let point = Self.flatPoint(kind, width: tool.width)
            selection.flatPen.strokeColor = uiColor(tool.color).cgColor
            selection.flatPen.opacity = Float(min(point.opacity, 1))
            // The layer zooms with the page; the finest pens are hairlines, kept 1 pt on screen.
            let drawn = CGFloat(InkNib(ink: StrokeRendering.Ink.for(kind), point: point).maximumWidth)
            selection.flatPen.lineWidth = max(drawn, 1 / max(viewport.zoomScale, 0.01))
            selection.flatPen.path = path
        case let .ended(stroke):
            selection.flatPen.path = nil
            commitFlatPen(stroke, kind: kind)
        case .cancelled:
            selection.flatPen.path = nil
        }
    }

    /// Reports the finished stroke and shows it on its page's canvas (if it has one) as pending, like a
    /// stroke PencilKit drew, until the document echoes it back.
    private func commitFlatPen(_ live: LiveStroke, kind: PenKind) {
        guard !live.samples.isEmpty else { return }
        let stroke = Self.flatStroke(kind, color: tool.color, width: tool.width, samples: live.samples)
        let pk = PencilKitConversion.pkStroke(from: stroke, color: uiColor(stroke.color))
        pending[live.page, default: []].append((stroke.id, pk))
        if let canvas = canvas(for: live.page), !canvas.isUsingTool {
            isSettingDrawing = true
            canvas.view.drawing.strokes.append(pk)
            isSettingDrawing = false
            canvas.ids.append(stroke.id)
        }
        delegate?.engine(self, didCommit: stroke, to: live.page)
    }

    /// The point every sample of a pressure-off stroke renders with: the pen's PencilKit width for the
    /// toolbar width (``PencilKitConversion/pencilKitWidth(for:width:)``, what a live stroke gets at neutral
    /// force and the popover preview draws), with the wash live watercolor strokes carry.
    static func flatPoint(_ kind: PenKind, width: Float) -> PointRendering {
        let size = Float(PencilKitConversion.pencilKitWidth(for: kind, width: width))
        return PointRendering(width: size, height: size, secondaryScale: kind == .brush ? Double(InkPreview.watercolorSecondaryScale) : 1)
    }

    /// A stroke of `samples` (already at neutral force) whose stored rendering is ``flatPoint(_:width:)``
    /// throughout, so PencilKit draws it one width whatever the samples' tilt.
    static func flatStroke(_ kind: PenKind, color: InkColor, width: Float, samples: [Sample]) -> Stroke {
        let stroke = Stroke(tool: kind, color: color, width: width, samples: samples)
        var rendering = stroke.derivedRendering
        let point = flatPoint(kind, width: width)
        rendering.points = Array(repeating: point, count: samples.count)
        if #available(iOS 27, *), kind == .brush {
            rendering.renderGroupID = UUID()
        }
        return Stroke(id: stroke.id, tool: kind, color: color, width: width, samples: samples, rendering: rendering)
    }
}
