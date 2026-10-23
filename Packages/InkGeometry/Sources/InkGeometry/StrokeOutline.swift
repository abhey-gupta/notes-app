import CoreGraphics
import Foundation
import InkModel

/// A stroke's filled outline as closed polygons, for vector PDF export and other CPU consumers.
///
/// The centerline is cut at sharp turns and at curls tighter than the stroke radius; each run becomes
/// one contour (left side forward, cap, right side backward, cap) with round caps at the cuts. All
/// contours share one orientation, so filling them together with the **nonzero** winding rule yields
/// exactly their union: no holes at folds, and self-crossing loops stay filled where they overlap.
/// Contours are not closed explicitly (last point ≠ first): `addLines` then `closeSubpath()` each.
public struct StrokeOutline: Sendable {
    /// Closed polygons (pt, page space), one per run.
    public var contours: [[Point2]]
    /// Bounds of all contour points. `.null` if empty.
    public var bounds: CGRect

    /// Total number of points across contours.
    public var pointCount: Int {
        contours.reduce(0) { $0 + $1.count }
    }

    /// Outline of `stroke` with its pen's standard profile.
    public init(stroke: Stroke, spacing: Float = 1) {
        self.init(centerline: Centerline(stroke: stroke, spacing: spacing))
    }

    /// Outline of a centerline. Round caps and joins use 3–16 arc segments per half-turn depending on radius.
    public init(centerline: Centerline) {
        let pts = centerline.points
        let radii = centerline.radii
        let n = pts.count
        contours = []
        guard n > 0 else {
            bounds = .null
            return
        }
        let roundEnds = centerline.capStyle == .round
        var start = 0
        if n > 2 {
            for i in 1 ..< n - 1 where Self.isJoin(pts[i - 1], pts[i], pts[i + 1], radius: radii[i]) {
                contours.append(Self.ring(pts, radii, start ... i, roundStart: start > 0 || roundEnds, roundEnd: true))
                start = i
            }
        }
        contours.append(Self.ring(pts, radii, start ... n - 1, roundStart: start > 0 || roundEnds, roundEnd: roundEnds))
        var box = BoundsBuilder()
        for ring in contours {
            for p in ring {
                box.add(p)
            }
        }
        bounds = box.rect
    }

    /// A turn the offset sides can't follow smoothly: sharper than ~15°, or tight enough that the
    /// inner side would fold back (radius × angle beyond half the shorter segment).
    private static func isJoin(_ a: Point2, _ p: Point2, _ b: Point2, radius: Float) -> Bool {
        let dIn = p - a
        let dOut = b - p
        let lIn = dot(dIn, dIn).squareRoot()
        let lOut = dot(dOut, dOut).squareRoot()
        let cosine = dot(dIn, dOut) / (lIn * lOut)
        guard cosine > 0.966 else { return true }
        let angle = acos(min(cosine, 1))
        return radius * angle > 0.5 * min(lIn, lOut)
    }

    /// One run as a ring: the envelope of the discs along it. Side points sit where each disc touches
    /// the envelope (tilted against the radius slope, so tapers stay tangent); round ends are arcs
    /// between the side points around the front/back. A single point yields a circle.
    private static func ring(_ pts: [Point2], _ radii: [Float], _ run: ClosedRange<Int>, roundStart: Bool, roundEnd: Bool) -> [Point2] {
        func unit(_ d: Point2) -> Point2 {
            d / dot(d, d).squareRoot()
        }
        let first = run.lowerBound
        let last = run.upperBound
        var left: [Point2] = []
        var right: [Point2] = []
        left.reserveCapacity(run.count)
        right.reserveCapacity(run.count)
        var tangents: [Point2] = []
        var angles: [Float] = [] // side-point angle from the tangent, π/2 for constant radius
        for i in run {
            let a = max(i - 1, first)
            let b = min(i + 1, last)
            var t = Point2(1, 0)
            var slope: Float = 0
            if a != b {
                t = a < i && i < b ? unit(unit(pts[i] - pts[a]) + unit(pts[b] - pts[i])) : unit(pts[b] - pts[a])
                let span = norm(pts[i] - pts[a]) + norm(pts[b] - pts[i])
                let flatEnd = (i == first && !roundStart) || (i == last && !roundEnd)
                slope = flatEnd ? 0 : min(max((radii[b] - radii[a]) / span, -0.9), 0.9)
            }
            let n = Point2(-t.y, t.x)
            let along = -slope * radii[i]
            let across = (1 - slope * slope).squareRoot() * radii[i]
            left.append(pts[i] + t * along + n * across)
            right.append(pts[i] + t * along - n * across)
            tangents.append(t)
            angles.append(atan2(across, along))
        }
        var ring = left
        ring.reserveCapacity(2 * run.count + 40)
        if roundEnd {
            let k = run.count - 1
            ring += arc(around: pts[last], tangent: tangents[k], radius: radii[last], from: angles[k], to: -angles[k])
        }
        ring += right.reversed()
        if roundStart {
            ring += arc(around: pts[first], tangent: tangents[0], radius: radii[first], from: -angles[0], to: angles[0] - 2 * .pi)
        }
        return ring
    }

    /// Clockwise arc (angles relative to `tangent`, decreasing), endpoints excluded.
    private static func arc(around center: Point2, tangent t: Point2, radius: Float, from a0: Float, to a1: Float) -> [Point2] {
        let n = Point2(-t.y, t.x)
        let perHalfTurn = min(max((radius.squareRoot() * 3).rounded(.up), 3), 16)
        let segments = max(Int((perHalfTurn * (a0 - a1) / .pi).rounded(.up)), 2)
        return (1 ..< segments).map { k in
            let a = a0 + (a1 - a0) * Float(k) / Float(segments)
            return center + radius * (t * cos(a) + n * sin(a))
        }
    }
}
