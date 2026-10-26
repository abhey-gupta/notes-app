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
    /// How long the live line stays after lift if the canvas never reports a render.
    static let flatPenRenderCap: TimeInterval = 0.5
    /// Live line → PencilKit stroke crossfade once the canvas has drawn it, seconds.
    static let flatPenFade: CFTimeInterval = 0.08

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
            selection.flatPenCanvas = nil
            selection.flatPen.removeAnimation(forKey: "fade")
            selection.flatPen.opacity = 1
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
            // The line stays until PencilKit has drawn the committed stroke beneath it (no gap at lift).
            if let canvas = commitFlatPen(stroke, kind: kind) {
                selection.flatPenCanvas = canvas
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.flatPenRenderCap) { [weak self, weak canvas] in
                    guard let self, let canvas, selection.flatPenCanvas === canvas else { return }
                    fadeOutFlatPen()
                }
            } else {
                selection.flatPen.path = nil
            }
        case .cancelled:
            selection.flatPen.path = nil
        }
    }

    /// `canvas` finished a render: the committed stroke is on screen, so the live line can go.
    func flatPenCanvasDidRender(_ canvas: PageCanvas) {
        guard selection.flatPenCanvas === canvas else { return }
        fadeOutFlatPen()
    }

    private func fadeOutFlatPen() {
        selection.flatPenCanvas = nil
        let layer = selection.flatPen
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = Self.flatPenFade
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
    }

    /// Reports the finished stroke and shows it on its page's canvas (if it has one) as pending, like a
    /// stroke PencilKit drew, until the document echoes it back.
    /// - Returns: The canvas now drawing it, if any.
    @discardableResult
    private func commitFlatPen(_ live: LiveStroke, kind: PenKind) -> PageCanvas? {
        guard !live.samples.isEmpty else { return nil }
        let stroke = Self.flatStroke(kind, color: tool.color, width: tool.width, samples: live.samples)
        let pk = PencilKitConversion.pkStroke(from: stroke, color: uiColor(stroke.color))
        pending[live.page, default: []].append((stroke.id, pk))
        var drawnBy: PageCanvas?
        if let canvas = canvas(for: live.page), !canvas.isUsingTool {
            isSettingDrawing = true
            canvas.view.drawing.strokes.append(pk)
            isSettingDrawing = false
            canvas.ids.append(stroke.id)
            drawnBy = canvas
        }
        delegate?.engine(self, didCommit: stroke, to: live.page)
        return drawnBy
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
