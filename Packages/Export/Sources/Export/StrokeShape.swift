import CoreGraphics
import InkGeometry
import InkModel

/// A centerline piece stroked at one width.
struct StrokedPath: Sendable {
    /// Line width (pt).
    var width: Float
    var path: CubicContour
}

/// How one stroke goes into the PDF: its centerline stroked in near-constant-width pieces, or (dots,
/// translucent ink whose width varies, extreme width changes) its filled outline.
///
/// A stroked centerline needs ~⅛ of the PDF coordinates of the filled outline: one curve instead of two
/// sides, no caps, and no contour cuts at every tight turn; PDF round caps and joins draw the same union
/// of discs `StrokeOutline` traces. Ballpoint and highlighter strokes are one piece. Pressure-varying
/// pens (fountain, brush) are split greedily into pieces whose radius spans at most twice the edge
/// tolerance, each stroked at its mid width; consecutive pieces share an end point and overlap in their
/// round caps, which is invisible for opaque ink only.
struct StrokeShape: Sendable {
    /// Edge error allowed (curve fit, and half a piece's width span), as a fraction of the stroke width.
    static let relativeTolerance: Float = 0.04
    /// Edge error floor (pt) for thin strokes: ~0.2 px at 400 % zoom.
    static let minimumTolerance: Float = 0.05
    /// Edge error ceiling (pt) for wide strokes (the pre-#62 outline tolerance).
    static let maximumTolerance: Float = 0.15
    /// Beyond this many pieces the stroke goes out as its outline.
    static let maximumPieces = 48

    var fills: [CubicContour] = []
    var strokes: [StrokedPath] = []
    /// Cap for ``strokes``: the pen's (round, or butt for the highlighter chisel).
    var cap: CGLineCap = .round

    var isEmpty: Bool {
        fills.isEmpty && strokes.isEmpty
    }

    /// Allowed distance (pt) between the exported edge and the exact outline for a stroke `width` wide.
    static func edgeTolerance(width: Float) -> Float {
        min(max(relativeTolerance * width, minimumTolerance), maximumTolerance)
    }

    /// - Parameter allowsOverlap: Whether pieces may overlap (opaque ink). Without it, a stroke that
    ///   needs more than one piece goes out as its outline.
    init(stroke: Stroke, allowsOverlap: Bool) {
        let centerline = Centerline(stroke: stroke)
        cap = centerline.capStyle == .butt ? .butt : .round
        if let pieces = Self.pieces(centerline, allowsOverlap: allowsOverlap) {
            strokes = pieces
        } else {
            let tolerance = Self.edgeTolerance(width: 2 * (centerline.radii.max() ?? 0))
            fills = StrokeOutline(centerline: centerline).contours.compactMap { CurveFit.fit(closed: $0, tolerance: tolerance) }
        }
    }

    /// Near-constant-width pieces, or `nil` if the stroke should be an outline.
    static func pieces(_ centerline: Centerline, allowsOverlap: Bool) -> [StrokedPath]? {
        let pts = centerline.points
        let radii = centerline.radii
        let n = pts.count
        guard n >= 2 else { return nil } // a dot: its outline is a circle
        // Point ranges and their mid widths (min + max radius).
        var ranges: [(ClosedRange<Int>, width: Float)] = []
        var start = 0
        var lo = radii[0]
        var hi = radii[0]
        for i in 1 ..< n {
            let r = radii[i]
            let newLo = min(lo, r)
            let newHi = max(hi, r)
            if newHi - newLo > 2 * edgeTolerance(width: newLo + newHi), i - 1 > start {
                ranges.append((start ... i - 1, lo + hi))
                guard allowsOverlap, ranges.count < maximumPieces else { return nil }
                start = i - 1
                lo = min(radii[i - 1], r)
                hi = max(radii[i - 1], r)
            } else {
                lo = newLo
                hi = newHi
            }
        }
        ranges.append((start ... n - 1, lo + hi))
        let out = ranges.compactMap { range, width in
            CurveFit.fit(open: Array(pts[range]), tolerance: edgeTolerance(width: width))
                .map { StrokedPath(width: width, path: $0) }
        }
        return out.isEmpty ? nil : out
    }
}
