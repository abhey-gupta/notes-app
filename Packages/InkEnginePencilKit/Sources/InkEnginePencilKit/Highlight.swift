import CoreGraphics
import InkGeometry
import InkModel
import PencilKit
import QuartzCore
import UIKit

/// Highlighter strokes (#120), drawn by the engine rather than PencilKit.
///
/// A highlight is a band of constant width with flat ends: the nib is a thin rectangle square to the
/// stroke, not PencilKit's marker chisel, which tilts with the Pencil's azimuth. Each stroke is one
/// translucent fill (``opacity``), so it never darkens where it crosses itself (PencilKit's marker does),
/// and every highlight sits beneath all other ink, so writing under it stays fully visible, like
/// GoodNotes. Everything that shows a page paints highlights first: the page view
/// (`PageLayerView.setHighlights(_:key:color:)`, one shape layer per stroke beneath the ink raster and
/// the canvas), rasters, thumbnails and the lifted-selection image (`RenderJob`); PDF export does the
/// same with multiply.
enum Highlight {
    /// Alpha of the band (the mock's `rgba(255,214,51,.55)`), shared with PDF export.
    static let opacity = CGFloat(PenProfile.highlighter.opacity)

    /// A dot (no travel) leaves the nib's footprint: this fraction of the band width across.
    static let nibAspect: CGFloat = 0.25

    static func isHighlight(_ stroke: Stroke) -> Bool {
        stroke.tool == .highlighter
    }

    /// The band's color: `base`, opaque. The band's translucency is applied to the whole stroke at once
    /// (a transparency layer, the shape layer's `opacity`), so overlapping parts of one stroke (joins, a
    /// stroke crossing itself) never add up.
    static func color(_ base: UIColor) -> CGColor {
        base.withAlphaComponent(1).cgColor
    }

    /// The band of one stroke, page space.
    struct Shape {
        var path: CGPath
        /// Width to stroke `path` with; 0: `path` is an outline to fill (a dot's nib).
        var lineWidth: CGFloat
    }

    /// Band width (pt): what the stroke's rendering draws (``InkModel/InkNib``: `width` for our ink, the
    /// widest extent of a pre-#120 marker chisel), else its base width.
    static func width(of stroke: Stroke) -> CGFloat {
        if let rendering = stroke.rendering, rendering.maximumDrawnWidth > 0 {
            return CGFloat(rendering.maximumDrawnWidth)
        }
        return CGFloat(stroke.width)
    }

    /// `stroke`'s band: its smoothed centerline (``InkGeometry/Centerline``) to stroke `width` wide with
    /// butt caps and round joins (the nib turning a corner), or a dot's nib to fill. `nil` without samples.
    static func shape(of stroke: Stroke) -> Shape? {
        let width = max(width(of: stroke), CGFloat(Centerline.minimumWidth))
        let finite = stroke.samples.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return nil }
        let path = CGMutablePath()
        let travels = finite.contains { hypot($0.x - first.x, $0.y - first.y) >= Centerline.minimumSampleSeparation }
        guard travels else {
            let across = max(width * nibAspect, 1)
            path.addRect(CGRect(x: CGFloat(first.x) - across / 2, y: CGFloat(first.y) - width / 2, width: across, height: width))
            return Shape(path: path, lineWidth: 0)
        }
        let centerline = Centerline(samples: finite, width: Float(width), profile: .highlighter)
        path.addLines(between: centerline.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        return Shape(path: path, lineWidth: width)
    }

    /// Paints `strokes` (highlights, in order) into `context`, page space, each one translucent fill.
    static func draw(_ strokes: [Stroke], color: (Stroke) -> CGColor, in context: CGContext) {
        for stroke in strokes {
            guard let shape = shape(of: stroke) else { continue }
            context.saveGState()
            context.setAlpha(opacity)
            context.beginTransparencyLayer(in: stroke.bounds, auxiliaryInfo: nil)
            context.setLineCap(.butt)
            context.setLineJoin(.round)
            context.addPath(shape.path)
            if shape.lineWidth > 0 {
                context.setStrokeColor(color(stroke))
                context.setLineWidth(shape.lineWidth)
                context.strokePath()
            } else {
                context.setFillColor(color(stroke))
                context.fillPath()
            }
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
        layer.lineCap = .butt
        layer.lineJoin = .round
        layer.fillColor = nil
        layer.opacity = Float(opacity)
        return layer
    }

    /// Shows `stroke` in `layer`: the layer covers the stroke's bounds (page space) and holds its band.
    static func configure(_ layer: CAShapeLayer, stroke: Stroke, color: CGColor) {
        let bounds = stroke.bounds
        guard let shape = shape(of: stroke), !bounds.isNull else {
            layer.path = nil
            return
        }
        layer.frame = bounds
        var toLayer = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        layer.path = shape.path.copy(using: &toLayer)
        if shape.lineWidth > 0 {
            layer.lineWidth = shape.lineWidth
            layer.strokeColor = color
            layer.fillColor = nil
        } else {
            layer.lineWidth = 0
            layer.strokeColor = nil
            layer.fillColor = color
        }
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
