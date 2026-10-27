/// The mark PencilKit paints for one stored point: its full extent along and across the pencil azimuth.
///
/// PencilKit does not draw a `PKStrokePoint` as wide as its `size`; each ink maps the size to a nib of
/// its own (measured on iOS 27 with `PKDrawing.image`, which the canvas matches pixel for pixel;
/// `InkWidthTests` in InkEnginePencilKitTests fails if a release changes it):
/// - pen, monoline: round, `2 × width − 4` (nothing below 2).
/// - fountain pen: a chisel along the azimuth, `2 × width − 4` long and `(width − 2) / 2` across.
/// - marker: a chisel along the azimuth, `1.45 × height − 0.5` long and `0.54 × width − 0.1` across.
/// - highlighter (ours, #120): round in effect, `width`: the band is `width` wide whatever the heading
///   (the nib is a thin rectangle square to the stroke, so its ends are flat and its width constant).
/// - watercolor: round, `1.63 × width` at full `secondaryScale`, shrinking with it (the wash).
/// - pencil, crayon: round, `1.75 × width − 0.3` and `1.37 × width − 0.2` of ink (textured).
/// - any other ink: round, the larger side of `size`.
/// Width, height and opacity, force, altitude otherwise don't change the mark.
public struct InkNib: Hashable, Sendable {
    /// Full extent (pt) along the azimuth.
    public var along: Float
    /// Full extent (pt) across the azimuth.
    public var across: Float

    public init(along: Float, across: Float) {
        self.along = along
        self.across = across
    }

    /// Same extent in every direction: the width perpendicular to the stroke is ``along`` whatever
    /// the azimuth.
    public var isRound: Bool {
        along == across
    }

    /// The widest the mark can be perpendicular to a stroke.
    public var maximumWidth: Float {
        max(along, across)
    }

    /// The nib `ink` paints for `point`. Non-finite sizes give a 1 pt round nib.
    public init(ink: String, point: PointRendering) {
        let w = point.width
        let h = point.height
        guard w.isFinite, h.isFinite else {
            self.init(along: 1, across: 1)
            return
        }
        switch ink {
        case StrokeRendering.Ink.pen, StrokeRendering.Ink.monoline:
            let d = max(2 * w - 4, 0)
            self.init(along: d, across: d)
        case StrokeRendering.Ink.fountainPen:
            self.init(along: max(2 * w - 4, 0), across: max((w - 2) / 2, 0))
        case StrokeRendering.Ink.marker:
            self.init(along: max(1.45 * h - 0.5, 0), across: max(0.54 * w - 0.1, 0))
        case StrokeRendering.Ink.highlighter:
            let d = max(w, 0)
            self.init(along: d, across: d)
        case StrokeRendering.Ink.watercolor:
            let wash = point.secondaryScale.isFinite ? Float(point.secondaryScale) : 1
            let d = max(w * min(1.69 * wash, Self.watercolorScale), 0)
            self.init(along: d, across: d)
        case StrokeRendering.Ink.pencil:
            let d = max(1.745 * w - 0.28, 0)
            self.init(along: d, across: d)
        case StrokeRendering.Ink.crayon:
            let d = max(1.37 * w - 0.19, 0)
            self.init(along: d, across: d)
        default:
            let d = max(w, h)
            self.init(along: d, across: d)
        }
    }

    /// Watercolor width per point size at full `secondaryScale`.
    static let watercolorScale: Float = 1.63

    /// The point size (square, default extras) that `ink` paints `width` wide: the inverse of
    /// ``init(ink:point:)`` for round nibs; chisels (fountain pen, marker) get `width` along the azimuth.
    public static func pointSize(ink: String, width: Float) -> Float {
        let w = width.isFinite ? max(width, 0) : 1
        switch ink {
        case StrokeRendering.Ink.pen, StrokeRendering.Ink.monoline, StrokeRendering.Ink.fountainPen:
            return w / 2 + 2
        case StrokeRendering.Ink.marker:
            return (w + 0.5) / 1.45
        case StrokeRendering.Ink.highlighter:
            return w
        case StrokeRendering.Ink.watercolor:
            return w / watercolorScale
        case StrokeRendering.Ink.pencil:
            return (w + 0.28) / 1.745
        case StrokeRendering.Ink.crayon:
            return (w + 0.19) / 1.37
        default:
            return w
        }
    }
}

public extension StrokeRendering {
    /// The widest any point's mark can be (``InkNib/maximumWidth``), 0 if none.
    var maximumDrawnWidth: Float {
        points.reduce(0) { max($0, InkNib(ink: ink, point: $1).maximumWidth) }
    }
}
