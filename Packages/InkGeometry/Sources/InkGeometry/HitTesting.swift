import CoreGraphics
import InkModel

public extension Centerline {
    /// Whether a disk touches the stroke outline (eraser hit test).
    ///
    /// Exact against the union of tapered capsules along the centerline (radius interpolated at the
    /// closest point). Butt caps are treated as round, overestimating by at most one radius at the ends.
    func intersects(circleCenter center: Point2, radius: Float) -> Bool {
        let n = points.count
        guard n > 0, radius.isFinite, overlaps(bounds, CGRect(
            x: CGFloat(center.x - radius), y: CGFloat(center.y - radius),
            width: CGFloat(2 * radius), height: CGFloat(2 * radius)
        )) else { return false }
        if n == 1 {
            return norm(center - points[0]) <= radius + radii[0]
        }
        for i in 0 ..< n - 1 {
            let a = points[i]
            let ab = points[i + 1] - a
            let u = min(max(dot(center - a, ab) / dot(ab, ab), 0), 1)
            let reach = radius + radii[i] + (radii[i + 1] - radii[i]) * u
            let d = center - (a + ab * u)
            if dot(d, d) <= reach * reach {
                return true
            }
        }
        return false
    }
}

public extension Stroke {
    /// Whether a disk (page space) touches this stroke's outline. Bounds-prefiltered, then
    /// ``Centerline/intersects(circleCenter:radius:)``. Cache a ``Centerline`` for repeated tests.
    func intersects(circleCenter center: CGPoint, radius: CGFloat) -> Bool {
        let probe = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        guard overlaps(bounds, probe) else { return false }
        return Centerline(stroke: self).intersects(circleCenter: Point2(center), radius: Float(radius))
    }
}

/// A closed freeform selection path (lasso). Point-in-polygon uses the even-odd rule.
public struct Lasso: Sendable {
    /// Minimum fraction of a stroke's samples inside the lasso for it to be selected (ARCHITECTURE.md §6).
    public static let selectionThreshold: Float = 0.5

    /// Polygon vertices (implicitly closed).
    public let points: [Point2]
    /// Bounds of ``points``.
    public let bounds: CGRect

    /// Creates a lasso from page-space points.
    public init(points: [Point2]) {
        self.points = points.filter { $0.x.isFinite && $0.y.isFinite }
        var box = BoundsBuilder()
        for p in self.points {
            box.add(p)
        }
        bounds = box.rect
    }

    /// Creates a lasso from `CGPoint`s (as delivered by the ink engine).
    public init(_ points: [CGPoint]) {
        self.init(points: points.map(Point2.init))
    }

    /// Even-odd point-in-polygon test. Fewer than 3 points contain nothing.
    public func contains(_ p: Point2) -> Bool {
        guard points.count >= 3,
              Float(bounds.minX) <= p.x, p.x <= Float(bounds.maxX),
              Float(bounds.minY) <= p.y, p.y <= Float(bounds.maxY) else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i]
            let b = points[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// `CGPoint` overload of the even-odd test.
    public func contains(_ p: CGPoint) -> Bool {
        contains(Point2(p))
    }

    /// Fraction of `stroke`'s raw samples inside the lasso (`0` for an empty stroke).
    public func insideFraction(of stroke: Stroke) -> Float {
        guard !stroke.samples.isEmpty, overlaps(bounds, stroke.bounds) else { return 0 }
        let inside = stroke.samples.count { contains(Point2($0.x, $0.y)) }
        return Float(inside) / Float(stroke.samples.count)
    }

    /// Whether `stroke` is selected: at least `threshold` of its samples are inside.
    public func selects(_ stroke: Stroke, threshold: Float = Lasso.selectionThreshold) -> Bool {
        let fraction = insideFraction(of: stroke)
        return fraction > 0 && fraction >= threshold
    }

    /// IDs of selected strokes, in input (z) order. Prefilter large pages with
    /// ``StrokeIndex/query(_:)`` on ``bounds``.
    public func selection(from strokes: some Sequence<Stroke>, threshold: Float = Lasso.selectionThreshold) -> [StrokeID] {
        strokes.filter { selects($0, threshold: threshold) }.map(\.id)
    }
}
