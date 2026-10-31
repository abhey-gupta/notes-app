import InkEngine
import InkModel
import UIKit

/// Ghost ink (#225, mock 05 C): the version of a page that sync replaced, drawn under the page's ink as
/// dashed centerlines in the selection color at 40 %, so the writer sees what Keep mine would bring back. It
/// lives in the page's layer view (beneath the ink image and the canvas), takes no touches and never enters
/// rasters, thumbnails or export.
extension PencilKitInkEngine {
    /// Ghost strokes are this faint.
    static let ghostOpacity: CGFloat = 0.4

    public func setGhost(_ strokes: [Stroke], on page: PageID) {
        ghosts[page] = strokes.isEmpty ? nil : strokes
        if let view = pageViews[page] {
            refreshGhost(view, page: page)
        }
    }

    func refreshGhost(_ view: PageLayerView, page: PageID) {
        view.setGhost(ghosts[page] ?? [], color: selectionColor.withAlphaComponent(Self.ghostOpacity).cgColor)
    }
}

extension PageLayerView {
    /// Fade in and out, seconds.
    static let ghostFade: CFTimeInterval = 0.25

    /// Shows `strokes` as ghost ink (one dashed shape layer each), rebuilding only when they changed; empty
    /// fades the ghost out.
    func setGhost(_ strokes: [Stroke], color: CGColor) {
        let ids = strokes.map(\.id)
        // Every layout pass comes here: nothing to do unless the strokes or their color changed.
        guard ids != ghostIDs || (!ids.isEmpty && color != ghostColor) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ghostColor = color
        guard ids != ghostIDs else {
            for case let layer as CAShapeLayer in ghostLayer.sublayers ?? [] {
                layer.strokeColor = color
                layer.fillColor = layer.fillColor == nil ? nil : color
            }
            return
        }
        let appears = ghostIDs.isEmpty
        ghostIDs = ids
        guard !strokes.isEmpty else {
            fadeGhost(to: 0) { [weak self] in
                guard let self, ghostIDs.isEmpty else { return }
                ghostLayer.sublayers = nil
            }
            return
        }
        ghostLayer.sublayers = strokes.map { Self.ghostLayer(for: $0, color: color, contentsScale: linesLayer.contentsScale) }
        if appears {
            ghostLayer.opacity = 0
            fadeGhost(to: 1)
        }
    }

    private func fadeGhost(to opacity: Float, completion: (() -> Void)? = nil) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ghostLayer.presentation()?.opacity ?? ghostLayer.opacity
        fade.toValue = opacity
        fade.duration = Self.ghostFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.setCompletionBlock(completion)
        ghostLayer.opacity = opacity
        ghostLayer.add(fade, forKey: "fade")
    }

    /// A stroke's centerline, dashed (the mock's 4/4 at a 2 pt line, scaling with the line).
    private static func ghostLayer(for stroke: Stroke, color: CGColor, contentsScale: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        let points = stroke.samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let width = min(max(CGFloat(stroke.width), 1), 6)
        if points.count == 1, let point = points.first {
            path.addEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
        } else {
            path.addLines(between: points)
        }
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = points.count == 1 ? color : nil
        layer.strokeColor = color
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        let dash = NSNumber(value: Double(max(4, 2 * width)))
        layer.lineDashPattern = [dash, dash]
        layer.contentsScale = contentsScale
        return layer
    }
}
