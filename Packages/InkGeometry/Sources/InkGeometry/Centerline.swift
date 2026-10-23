import CoreGraphics
import InkModel

/// Smoothed, evenly resampled stroke centerline with per-point radius: the input to tessellation,
/// outlines and exact hit tests.
///
/// Built from raw samples by: dropping non-finite and near-duplicate samples, estimating speed,
/// centripetal Catmull-Rom interpolation (α = 0.5: no cusps or self-intersections within a segment),
/// resampling every ~`spacing` pt, and evaluating the ``PenProfile`` width at each sample
/// (interpolated between samples). Spline points are clamped to the samples' bounding box, so geometry
/// never exceeds ``InkModel/Stroke/bounds``.
public struct Centerline: Sendable {
    /// Samples closer than this (pt) to the previous kept sample are dropped.
    public static let minimumSampleSeparation: Float = 0.05
    /// Base widths below this (pt) are clamped up.
    public static let minimumWidth: Float = 0.1

    /// Resampled positions, ~`spacing` apart; consecutive points are distinct.
    public private(set) var points: [Point2] = []
    /// Outline half-width at each point.
    public private(set) var radii: [Float] = []
    /// Cumulative arc length at each point (first is 0).
    public private(set) var arcLengths: [Float] = []
    /// End-cap shape from the profile.
    public let capStyle: CapStyle
    private var box = BoundsBuilder()

    /// Bounds of the outline (points outset by their radii). `.null` if empty.
    public var bounds: CGRect {
        box.rect
    }

    /// Total length in points.
    public var length: Float {
        arcLengths.last ?? 0
    }

    /// Centerline for `stroke` with its pen's standard profile.
    public init(stroke: Stroke, spacing: Float = 1) {
        self.init(samples: stroke.samples, width: stroke.width, profile: PenProfile(stroke.tool), spacing: spacing)
    }

    /// Centerline for raw `samples` drawn at base `width` with `profile`.
    /// - Parameter spacing: Target distance between resampled points (pt), clamped to `≥ 0.05`.
    public init(samples: [Sample], width: Float, profile: PenProfile, spacing: Float = 1) {
        capStyle = profile.capStyle
        let halfWidth = (width.isFinite ? max(width, Self.minimumWidth) : 1) / 2
        let filtered = Self.filter(samples, halfWidth: halfWidth, profile: profile)
        switch filtered.points.count {
        case 0:
            return
        case 1:
            let p = filtered.points[0]
            let r = filtered.radii[0]
            if capStyle == .butt {
                // A chisel tap: short flat mark rather than a zero-length segment.
                append(p - Point2(r / 2, 0), radius: r)
                append(p + Point2(r / 2, 0), radius: r)
            } else {
                append(p, radius: r)
            }
        default:
            resample(filtered, spacing: spacing.isFinite ? max(spacing, 0.05) : 1)
        }
    }

    private struct Filtered {
        var points: [Point2] = []
        var radii: [Float] = []
        var box = BoundsBuilder()
    }

    /// Drops non-finite and near-duplicate samples; radius per kept sample from the profile, using
    /// EMA-smoothed speed (pt/s).
    private static func filter(_ samples: [Sample], halfWidth: Float, profile: PenProfile) -> Filtered {
        var out = Filtered()
        var pressureTilt: [Point2] = []
        var speeds: [Float] = []
        out.points.reserveCapacity(samples.count)
        pressureTilt.reserveCapacity(samples.count)
        speeds.reserveCapacity(samples.count)
        var lastT: Float = 0
        var speed: Float = 0
        for s in samples where s.x.isFinite && s.y.isFinite {
            let p = Point2(s.x, s.y)
            if let last = out.points.last {
                let d = norm(p - last)
                if d < minimumSampleSeparation {
                    continue
                }
                let dt = s.t - lastT
                if dt > 1e-4, dt.isFinite {
                    let raw = min(d / dt, 10000)
                    speed = out.points.count == 1 ? raw : speed + 0.35 * (raw - speed)
                }
            }
            lastT = s.t
            out.points.append(p)
            pressureTilt.append(Point2(s.force, s.altitude))
            speeds.append(speed)
            out.box.add(p)
        }
        // The first sample has no speed of its own; borrow the second's.
        if speeds.count > 1 {
            speeds[0] = speeds[1]
        }
        out.radii = speeds.indices.map { i in
            halfWidth * profile.widthScale(force: pressureTilt[i].x, speed: speeds[i], altitude: pressureTilt[i].y)
        }
        return out
    }

    /// Centripetal Catmull-Rom → cubic Hermite per segment, resampled at ~`spacing`.
    private mutating func resample(_ kept: Filtered, spacing: Float) {
        let pts = kept.points
        let m = pts.count
        points.reserveCapacity(m * 3)
        radii.reserveCapacity(m * 3)
        arcLengths.reserveCapacity(m * 3)
        for i in 0 ..< m - 1 {
            let p1 = pts[i]
            let p2 = pts[i + 1]
            // Endpoints are extended by reflection so the end segments are well defined.
            let p0 = i > 0 ? pts[i - 1] : 2 * p1 - p2
            let p3 = i + 2 < m ? pts[i + 2] : 2 * p2 - p1
            let d12 = norm(p2 - p1)
            let t01 = norm(p1 - p0).squareRoot()
            let t12 = d12.squareRoot()
            let t23 = norm(p3 - p2).squareRoot()
            let m1 = (p2 - p1) + t12 * ((p1 - p0) / t01 - (p2 - p0) / (t01 + t12))
            let m2 = (p2 - p1) + t12 * ((p3 - p2) / t23 - (p3 - p1) / (t12 + t23))
            let a = 2 * (p1 - p2) + m1 + m2
            let b = -3 * (p1 - p2) - 2 * m1 - m2
            let r1 = kept.radii[i]
            let r2 = kept.radii[i + 1]
            // Tolerance keeps a 10.000001 pt chord at 10 steps.
            let steps = min(max(Int((d12 / spacing - 1e-3).rounded(.up)), 1), 1024)
            let du = 1 / Float(steps)
            for j in 0 ..< steps {
                let u = Float(j) * du
                let q = ((a * u + b) * u + m1) * u + p1
                // Clamp overshoot to the samples' box so geometry stays inside Stroke.bounds.
                append(pointwiseMin(pointwiseMax(q, kept.box.lower), kept.box.upper), radius: r1 + (r2 - r1) * u)
            }
        }
        append(pts[m - 1], radius: kept.radii[m - 1])
    }

    @inline(__always) private mutating func append(_ p: Point2, radius: Float) {
        if let last = points.last {
            let d = norm(p - last)
            guard d > 1e-3 else { return }
            arcLengths.append(arcLengths[arcLengths.count - 1] + d)
        } else {
            arcLengths.append(0)
        }
        points.append(p)
        radii.append(radius)
        box.add(p, radius: radius)
    }
}
