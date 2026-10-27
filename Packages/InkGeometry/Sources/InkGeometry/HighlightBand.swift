import InkModel

/// The shape a highlighter stroke paints (#120): a tall, thin rectangular nib, upright whatever the stroke's
/// direction or the Pencil's tilt, swept along the stroke. Drawn sideways it leaves a band ``height`` tall
/// with flat upright ends; drawn up or down, a line ``thickness`` wide. Like GoodNotes, a hook or tap where
/// the Pencil lands or lifts only grows the band a little, it never cuts the end at an angle.
///
/// The band is a list of polygons whose union is the swept area: the stroke's centerline split into runs
/// that move one way in x and one way in y, each run's sweep one polygon (between the centerline traced by
/// the nib's two leading corners). Every polygon winds the same way (positive signed area in page
/// space), so filling them all with the nonzero rule paints the union once.
///
/// The nib's corners are rounded (``cornerRadius``) so the band's ends and turns look soft, not cut: the
/// polygons are the sweep of the nib shrunk by the radius, and the band is them grown by it again, i.e.
/// filled and stroked ``cornerRadius`` × 2 wide with round joins, as one opaque shape (then made
/// translucent as a whole), so the overlap of fill and stroke never shows.
public struct HighlightBand: Sendable {
    /// Nib thickness per band height.
    public static let nibAspect: Float = 0.25
    /// Corner radius per half nib thickness: nearly round across the thin side.
    public static let cornerRoundness: Float = 0.9
    /// The nib is never thinner than this (pt).
    public static let minimumThickness: Float = 1

    /// Nib height (pt): the band's height drawn sideways.
    public let height: Float
    /// Nib thickness (pt).
    public let thickness: Float
    /// Radius (pt) of the nib's corners: grow ``polygons`` by it (stroke them `2 ×` as wide, round joins).
    public let cornerRadius: Float
    /// Closed polygons, page space; empty without samples.
    public private(set) var polygons: [[Point2]] = []

    /// The band of `stroke`, ``height(of:)`` tall.
    public init(stroke: Stroke) {
        self.init(samples: stroke.samples, height: Self.height(of: stroke))
    }

    /// The band of a nib `height` tall swept along `samples`.
    public init(samples: [Sample], height: Float) {
        let h = height.isFinite ? max(height, Centerline.minimumWidth) : 1
        self.height = h
        let t = max(h * Self.nibAspect, Self.minimumThickness)
        thickness = t
        let r = t / 2 * Self.cornerRoundness
        cornerRadius = r
        let (a, b) = (t / 2 - r, h / 2 - r)
        let points = Self.path(samples, height: h)
        guard let first = points.first else { return }
        guard points.count > 1 else {
            polygons = [Self.positive(Self.rectangle(at: first, a: a, b: b))]
            return
        }
        for run in Self.monotoneRuns(points) {
            polygons.append(Self.positive(Self.sweep(run, a: a, b: b)))
        }
    }

    /// Band height (pt) for `stroke`: what its rendering draws (our ink: the point width; a pre-#120
    /// PencilKit marker: its chisel's widest extent), else its base width.
    public static func height(of stroke: Stroke) -> Float {
        if let rendering = stroke.rendering, rendering.maximumDrawnWidth > 0 {
            return rendering.maximumDrawnWidth
        }
        return stroke.width
    }

    // MARK: Geometry

    /// Points on either side averaged into each centerline point (~1 pt apart): evens out hand tremor,
    /// which a wide band would otherwise trace along its edges.
    static let smoothingRadius = 3

    /// The path the nib follows: the centerline through the finite samples (one point for a dot), each
    /// point averaged with ``smoothingRadius`` neighbors on either side (fewer near the ends, which stay put).
    static func path(_ samples: [Sample], height: Float) -> [Point2] {
        let finite = samples.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return [] }
        let start = Point2(first.x, first.y)
        let travels = finite.contains { norm(Point2($0.x, $0.y) - start) >= Centerline.minimumSampleSeparation }
        guard travels else { return [start] }
        let points = Centerline(samples: finite, width: height, profile: .highlighter, spacing: 1).points
        guard points.count > 2 else { return points }
        var prefix = [Point2.zero]
        prefix.reserveCapacity(points.count + 1)
        for p in points {
            prefix.append(prefix[prefix.count - 1] + p)
        }
        let last = points.count - 1
        return points.indices.map { i in
            let k = min(smoothingRadius, i, last - i)
            return (prefix[i + k + 1] - prefix[i - k]) / Float(2 * k + 1)
        }
    }

    /// Splits `points` into runs monotone in both x and y; consecutive runs share an end point.
    static func monotoneRuns(_ points: [Point2]) -> [[Point2]] {
        var runs: [[Point2]] = []
        var run = [points[0]]
        var sx: Float = 0
        var sy: Float = 0
        for p in points.dropFirst() {
            let d = p - run[run.count - 1]
            let dx: Float = d.x > 0 ? 1 : d.x < 0 ? -1 : 0
            let dy: Float = d.y > 0 ? 1 : d.y < 0 ? -1 : 0
            if (dx != 0 && sx != 0 && dx != sx) || (dy != 0 && sy != 0 && dy != sy) {
                let last = run[run.count - 1]
                runs.append(run)
                run = [last]
                sx = 0
                sy = 0
            }
            if dx != 0 {
                sx = dx
            }
            if dy != 0 {
                sy = dy
            }
            run.append(p)
        }
        runs.append(run)
        return runs
    }

    /// The area an upright rectangle (half-sizes `a` across, `b` tall) covers swept along `run`, which
    /// moves one way in x and one way in y: the trailing corner at the start, the run traced by one side
    /// corner, the leading corner at the end, back along the run by the other side corner.
    static func sweep(_ run: [Point2], a: Float, b: Float) -> [Point2] {
        guard let first = run.first, let last = run.last else { return [] }
        let d = last - first
        let sx: Float = d.x < 0 ? -1 : 1
        let sy: Float = d.y < 0 ? -1 : 1
        var polygon: [Point2] = []
        polygon.reserveCapacity(2 * run.count + 2)
        polygon.append(first + Point2(-sx * a, -sy * b))
        for p in run {
            polygon.append(p + Point2(sx * a, -sy * b))
        }
        polygon.append(last + Point2(sx * a, sy * b))
        for p in run.reversed() {
            polygon.append(p + Point2(-sx * a, sy * b))
        }
        return polygon
    }

    private static func rectangle(at p: Point2, a: Float, b: Float) -> [Point2] {
        [p + Point2(-a, -b), p + Point2(a, -b), p + Point2(a, b), p + Point2(-a, b)]
    }

    /// `polygon`, reversed if its signed area is negative.
    private static func positive(_ polygon: [Point2]) -> [Point2] {
        var twiceArea: Float = 0
        for i in polygon.indices {
            let p = polygon[i]
            let q = polygon[(i + 1) % polygon.count]
            twiceArea += p.x * q.y - q.x * p.y
        }
        return twiceArea < 0 ? polygon.reversed() : polygon
    }
}
