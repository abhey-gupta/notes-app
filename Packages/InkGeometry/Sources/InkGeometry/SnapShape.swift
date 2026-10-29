import Foundation

/// A perfect shape a held stroke snaps to (#165): a line, an ellipse or a closed polygon, in page space.
///
/// ``ShapeRecognizer`` finds it; while the Pencil stays down it follows the Pencil
/// (``adjusted(anchor:to:)``); on lift its ``outline(spacing:)`` becomes the committed stroke's samples.
public enum SnapShape: Hashable, Sendable {
    /// From the first point to the second.
    case line(Point2, Point2)
    /// Semi-axes `radii.x` along `rotation` (radians from +x toward +y) and `radii.y` across it.
    case ellipse(center: Point2, radii: Point2, rotation: Float)
    /// Corners in drawing order; the edge from the last back to the first closes it.
    case polygon([Point2])

    /// Angles that snap: every 45°.
    public static let angleStep: Float = .pi / 4
    /// How close (radians) an angle must be to a multiple of ``angleStep`` to snap to it: 6°.
    public static let angleTolerance: Float = 6 * .pi / 180

    /// What closed shapes scale and rotate about: the ellipse center, the polygon's corner centroid, the line's midpoint.
    public var center: Point2 {
        switch self {
        case let .line(a, b): (a + b) / 2
        case let .ellipse(center, _, _): center
        case let .polygon(corners): corners.reduce(Point2.zero, +) / Float(max(corners.count, 1))
        }
    }

    /// The shape after the Pencil moved from `anchor` (where it was when the shape snapped) to `point`:
    /// a line's end follows the Pencil (its angle snapping, ``snapped(_:)``); a closed shape scales and
    /// rotates about its ``center`` so `anchor` lands on `point`, the rotation snapping to whole 45°s.
    public func adjusted(anchor: Point2, to point: Point2) -> SnapShape {
        if case let .line(a, _) = self {
            return .line(a, Self.lineEnd(from: a, to: point))
        }
        let c = center
        let from = anchor - c
        let to = point - c
        guard norm(from) > 1, norm(to) > 1e-3 else { return self }
        let scale = min(max(norm(to) / norm(from), 0.05), 20)
        let rotation = Self.snapped(atan2(to.y, to.x) - atan2(from.y, from.x))
        return transformed(about: c, scale: scale, rotation: rotation)
    }

    /// Scaled by `scale` and rotated by `rotation` about `pivot`.
    public func transformed(about pivot: Point2, scale: Float, rotation: Float) -> SnapShape {
        let (cosR, sinR) = (cos(rotation), sin(rotation))
        let map = { (p: Point2) -> Point2 in
            let d = (p - pivot) * scale
            return pivot + Point2(d.x * cosR - d.y * sinR, d.x * sinR + d.y * cosR)
        }
        switch self {
        case let .line(a, b): return .line(map(a), map(b))
        case let .ellipse(center, radii, angle): return .ellipse(center: map(center), radii: radii * scale, rotation: angle + rotation)
        case let .polygon(corners): return .polygon(corners.map(map))
        }
    }

    /// Points along the shape, at most `spacing` apart, for a stroke's samples. Closed shapes end where
    /// they start. Ends and corners are repeated three times: PencilKit draws a stroke as a B-spline
    /// through its points' neighborhood, and only a tripled point is passed through exactly (a sharp corner).
    public func outline(spacing: Float = 2) -> [Point2] {
        let step = max(spacing, 0.25)
        switch self {
        case let .line(a, b):
            return [a, a] + Self.segment(a, b, step: step) + [b, b]
        case let .ellipse(center, radii, rotation):
            return Self.ellipsePoints(center: center, radii: radii, rotation: rotation, step: step)
        case let .polygon(corners):
            guard let first = corners.first else { return [] }
            var points: [Point2] = []
            for (i, corner) in corners.enumerated() {
                points += [corner, corner] + Self.segment(corner, corners[(i + 1) % corners.count], step: step).dropLast()
            }
            return points + [first, first, first]
        }
    }

    /// `angle` moved onto the nearest multiple of ``angleStep`` when within ``angleTolerance`` of it.
    public static func snapped(_ angle: Float) -> Float {
        let nearest = (angle / angleStep).rounded() * angleStep
        return abs(angle - nearest) <= angleTolerance ? nearest : angle
    }

    /// The end of a line from `start` toward `point`, its angle ``snapped(_:)`` (same length).
    static func lineEnd(from start: Point2, to point: Point2) -> Point2 {
        let d = point - start
        let length = norm(d)
        guard length > 0 else { return point }
        let angle = snapped(atan2(d.y, d.x))
        return start + Point2(cos(angle), sin(angle)) * length
    }

    /// `a` to `b` inclusive, at most `step` apart.
    private static func segment(_ a: Point2, _ b: Point2, step: Float) -> [Point2] {
        let count = max(Int((norm(b - a) / step).rounded(.up)), 1)
        return (0 ... count).map { a + (b - a) * (Float($0) / Float(count)) }
    }

    private static func ellipsePoints(center: Point2, radii: Point2, rotation: Float, step: Float) -> [Point2] {
        // Ramanujan's perimeter approximation.
        let (a, b) = (abs(radii.x), abs(radii.y))
        let h = (a - b) * (a - b) / max((a + b) * (a + b), 1e-6)
        let perimeter = Float.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
        let count = max(Int((perimeter / step).rounded(.up)), 24)
        let (cosR, sinR) = (cos(rotation), sin(rotation))
        return (0 ... count).map { i in
            let t = 2 * Float.pi * Float(i) / Float(count)
            let p = Point2(a * cos(t), b * sin(t))
            return center + Point2(p.x * cosR - p.y * sinR, p.x * sinR + p.y * cosR)
        }
    }
}
