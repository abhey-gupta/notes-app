import CoreGraphics
import InkGeometry
import InkModel
import PencilKit
import QuartzCore
import UIKit

/// Highlighter strokes (#120), drawn by the engine rather than PencilKit.
///
/// A highlight is a tall, thin, upright nib swept along the stroke (``InkGeometry/HighlightBand``), not
/// PencilKit's marker chisel, which tilts with the Pencil's azimuth. Each stroke is one
/// translucent fill (``opacity``), so it never darkens where it crosses itself (PencilKit's marker does),
/// and every highlight sits beneath all other ink, so writing under it stays fully visible, like
/// GoodNotes. Everything that shows a page paints highlights first: the page view
/// (`PageLayerView.setHighlights(_:key:color:)`, one shape layer per stroke beneath the ink raster and
/// the canvas), rasters, thumbnails and the lifted-selection image (`RenderJob`); PDF export does the
/// same with multiply.
enum Highlight {
    /// Alpha of the band (the mock's `rgba(255,214,51,.55)`), shared with PDF export.
    static let opacity = CGFloat(PenProfile.highlighter.opacity)

    static func isHighlight(_ stroke: Stroke) -> Bool {
        stroke.tool == .highlighter
    }

    /// The band's color: `base`, opaque. The band's translucency is applied to the whole stroke at once
    /// (a transparency layer, the shape layer's `opacity`), so overlapping parts of one stroke (joins, a
    /// stroke crossing itself) never add up.
    static func color(_ base: UIColor) -> CGColor {
        base.withAlphaComponent(1).cgColor
    }

    /// Band height (pt) of `stroke` (``InkGeometry/HighlightBand/height(of:)``).
    static func width(of stroke: Stroke) -> CGFloat {
        CGFloat(HighlightBand.height(of: stroke))
    }

    /// `stroke`'s band (``InkGeometry/HighlightBand``) as a path to fill with the nonzero rule, page space;
    /// `nil` without samples.
    static func path(of stroke: Stroke) -> CGPath? {
        let band = HighlightBand(stroke: stroke)
        guard !band.polygons.isEmpty else { return nil }
        let path = CGMutablePath()
        for polygon in band.polygons {
            path.addLines(between: polygon.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            path.closeSubpath()
        }
        return path
    }

    /// Paints `strokes` (highlights, in order) into `context`, page space, each one translucent fill.
    static func draw(_ strokes: [Stroke], color: (Stroke) -> CGColor, in context: CGContext) {
        for stroke in strokes {
            guard let path = path(of: stroke) else { continue }
            context.saveGState()
            context.setAlpha(opacity)
            context.beginTransparencyLayer(in: stroke.bounds, auxiliaryInfo: nil)
            context.addPath(path)
            context.setFillColor(color(stroke))
            context.fillPath(using: .winding)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// A highlighter stroke of `samples` whose stored rendering is the band the engine draws
    /// (``InkModel/StrokeRendering/Ink/highlighter``, `width` wide throughout).
    static func stroke(id: StrokeID = StrokeID(), color: InkColor, width: Float, samples: [Sample]) -> Stroke {
        let plain = Stroke(id: id, tool: .highlighter, color: color, width: width, samples: samples)
        return Stroke(id: id, tool: .highlighter, color: color, width: width, samples: samples, rendering: plain.derivedRendering)
    }

    /// `template` over `samples`: same ID (so the same seed), color and width.
    static func stroke(_ template: Stroke, samples: [Sample]) -> Stroke {
        stroke(id: template.id, color: template.color, width: template.width, samples: samples)
    }

    // MARK: Layers

    /// A shape layer for one highlight, placed by ``configure(_:stroke:color:)``.
    static func makeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.anchorPoint = .zero
        layer.fillRule = .nonZero
        layer.strokeColor = nil
        layer.lineWidth = 0
        layer.opacity = Float(opacity)
        return layer
    }

    /// Shows `stroke` in `layer`: the layer covers the stroke's bounds (page space) and fills its band.
    static func configure(_ layer: CAShapeLayer, stroke: Stroke, color: CGColor) {
        let bounds = stroke.bounds
        guard let path = path(of: stroke), !bounds.isNull else {
            layer.path = nil
            return
        }
        layer.frame = bounds
        var toLayer = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        layer.path = path.copy(using: &toLayer)
        layer.fillColor = color
    }
}

/// A stroke reported via `didCommit` and kept by the engine until the document echoes it back: the ink
/// strokes' PencilKit stroke stays on the canvas, a highlight is drawn by the page view.
struct PendingStroke {
    let stroke: Stroke
    /// The PencilKit stroke on the canvas; `nil` for a highlight.
    let pk: PKStroke?

    var id: StrokeID {
        stroke.id
    }

    var isHighlight: Bool {
        Highlight.isHighlight(stroke)
    }

    /// The ID and PencilKit stroke of an ink stroke; `nil` for a highlight.
    var ink: (id: StrokeID, pk: PKStroke)? {
        pk.map { (stroke.id, $0) }
    }
}
