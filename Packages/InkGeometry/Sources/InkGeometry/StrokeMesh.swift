import CoreGraphics
import InkModel

/// One triangle-strip vertex, laid out for direct upload to a Metal vertex buffer.
///
/// Layout (24 bytes, stride 24, 4-byte floats, no padding):
///
/// | offset | field       | Metal       | meaning                                                   |
/// |-------:|-------------|-------------|-----------------------------------------------------------|
/// |      0 | `position`  | `float2`    | page-space position (pt)                                   |
/// |      8 | `edge`      | `float2`    | `(along, across)`: pt beyond the nearest end cap (≥ 0, 0 in the body), signed pt from the
/// centerline |
/// |     16 | `radius`    | `float`     | outline half-width (pt) at this point                       |
/// |     20 | `arcLength` | `float`     | distance along the centerline (pt), for grain/texture      |
///
/// Fragment coverage (interpolated attributes, `ppp` = pixels per point):
/// ```
/// round caps: d = length(float2(max(edge.x, 0), edge.y))
/// butt caps:  d = edge.x > 0 ? max(abs(edge.y), radius + edge.x) : abs(edge.y)   // ends at the end plane
/// hard edge:  coverage = saturate((radius - d) * ppp + 0.5)
/// soft edge:  coverage = 1 - smoothstep(radius * (1 - edgeSoftness), radius, d)   // PenProfile.edgeSoftness
/// ```
/// Matching MSL: `struct StrokeVertex { float2 position; float2 edge; float radius; float arcLength; };`
public struct StrokeVertex: Hashable, Sendable, BitwiseCopyable {
    /// Page-space position (pt).
    public var position: Point2
    /// `(along, across)` signed-distance coordinates (pt); see the type docs.
    public var edge: Point2
    /// Outline half-width (pt).
    public var radius: Float
    /// Arc length along the centerline (pt).
    public var arcLength: Float

    /// Creates a vertex.
    public init(position: Point2, edge: Point2, radius: Float, arcLength: Float) {
        self.position = position
        self.edge = edge
        self.radius = radius
        self.arcLength = arcLength
    }
}

/// A stroke's GPU geometry: one triangle strip (draw `vertices.count` vertices as `.triangleStrip`).
///
/// Every centerline point contributes a left/right vertex pair offset by `radius + fringe` along the
/// normal; an extra pair at each end extends the strip to cover the caps. At sharp turns (> 30°) the
/// strip ends with a cap and restarts with one, so corners come out round instead of chamfered; the
/// two bridging triangles have zero coverage. Winding alternates and tight curls overlap themselves,
/// so disable culling, and draw translucent strokes (highlighter) through a coverage pass (e.g. max
/// blending into an offscreen target) to avoid double-blending. Each stroke is its own strip: draw
/// per stroke, or concatenate with indexed primitive restart.
public struct StrokeMesh: Sendable {
    /// Strip vertices: `2 × (centerline points + 2)`, plus 6 per corner break.
    public var vertices: [StrokeVertex]
    /// Cap style to use in the fragment coverage function.
    public var capStyle: CapStyle
    /// Bounds of all vertex positions (includes the AA fringe).
    public var bounds: CGRect

    /// Number of triangles in the strip.
    public var triangleCount: Int {
        max(vertices.count - 2, 0)
    }
}

/// Turns centerlines into ``StrokeMesh`` triangle strips.
public enum StrokeTessellator {
    /// Default anti-aliasing fringe (pt) beyond the outline.
    public static let defaultFringe: Float = 1
    /// Largest fringe that keeps meshes inside ``InkModel/Stroke/bounds`` (`√2 × maxFringe ≤ Stroke.boundsMargin`).
    public static let maxFringe: Float = 2
    /// Turns sharper than this (cos of 30°) break the strip into capped pieces (round caps only).
    static let breakCosine: Float = 0.866

    /// Full pipeline: smooth, resample, apply the pen profile, tessellate.
    /// - Parameters:
    ///   - fringe: Extra extent (pt) beyond the outline for AA coverage; use ≥ 1 device pixel.
    ///     Clamped to `0...maxFringe` so the mesh stays inside `stroke.bounds`.
    ///   - spacing: Centerline resampling distance (pt).
    public static func mesh(for stroke: Stroke, fringe: Float = defaultFringe, spacing: Float = 1) -> StrokeMesh {
        mesh(for: Centerline(stroke: stroke, spacing: spacing), fringe: fringe)
    }

    /// Tessellates an existing centerline.
    public static func mesh(for centerline: Centerline, fringe: Float = defaultFringe) -> StrokeMesh {
        var vertices: [StrokeVertex] = []
        let bounds = appendVertices(for: centerline, fringe: fringe, to: &vertices)
        return StrokeMesh(vertices: vertices, capStyle: centerline.capStyle, bounds: bounds)
    }

    /// Appends the strip for `centerline` to `vertices` (reuse one buffer across strokes to avoid allocation).
    /// - Returns: Bounds of the appended vertices (`.null` if the centerline is empty).
    @discardableResult
    public static func appendVertices(for centerline: Centerline, fringe: Float, to vertices: inout [StrokeVertex]) -> CGRect {
        let n = centerline.points.count
        guard n > 0 else { return .null }
        var strip = StripWriter(
            centerline: centerline,
            fringe: fringe.isFinite ? min(max(fringe, 0), maxFringe) : defaultFringe
        )
        let roundCaps = centerline.capStyle == .round
        // Take the caller's buffer so appends stay in place (unique reference), then hand it back.
        swap(&strip.vertices, &vertices)
        defer { swap(&strip.vertices, &vertices) }
        strip.vertices.reserveCapacity(strip.vertices.count + 2 * (n + 2))

        var tangent = strip.centralTangent(0, fallback: Point2(1, 0))
        strip.cap(0, tangent: tangent, outward: -1, round: roundCaps)
        for i in 0 ..< n {
            if roundCaps, let (tIn, tOut) = strip.cornerBreak(at: i) {
                strip.cornerCaps(i, tIn: tIn, tOut: tOut)
                tangent = tOut
            } else {
                tangent = strip.centralTangent(i, fallback: tangent)
                strip.body(i, normal: Point2(-tangent.y, tangent.x))
            }
        }
        strip.cap(n - 1, tangent: tangent, outward: 1, round: roundCaps)
        return strip.box.rect
    }
}

/// Emits vertex pairs for one centerline.
private struct StripWriter {
    let points: [Point2]
    let radii: [Float]
    let arcs: [Float]
    let fringe: Float
    var box = BoundsBuilder()
    var vertices: [StrokeVertex] = []

    init(centerline: Centerline, fringe: Float) {
        points = centerline.points
        radii = centerline.radii
        arcs = centerline.arcLengths
        self.fringe = fringe
    }

    /// Left/right vertices at `center ± normal × extent`.
    mutating func pair(_ center: Point2, _ normal: Point2, _ extent: Float, along: Float, _ i: Int) {
        let left = center + normal * extent
        let right = center - normal * extent
        vertices.append(StrokeVertex(position: left, edge: Point2(along, extent), radius: radii[i], arcLength: arcs[i]))
        vertices.append(StrokeVertex(position: right, edge: Point2(along, -extent), radius: radii[i], arcLength: arcs[i]))
        box.add(left)
        box.add(right)
    }

    /// Unit central-difference tangent at `i`, or `fallback` where neighbors coincide.
    func centralTangent(_ i: Int, fallback: Point2) -> Point2 {
        let d = points[min(i + 1, points.count - 1)] - points[max(i - 1, 0)]
        let len2 = dot(d, d)
        return len2 > 1e-12 ? d / len2.squareRoot() : fallback
    }

    /// End cap pair at point `i`, offset along the stroke `tangent` backwards (`outward` −1, start)
    /// or forwards (+1, end). The normal stays `perp(tangent)` so left/right never swap.
    mutating func cap(_ i: Int, tangent: Point2, outward: Float, round: Bool) {
        let extent = radii[i] + fringe
        let along = round ? extent : fringe
        pair(points[i] + tangent * (outward * along), Point2(-tangent.y, tangent.x), extent, along: along, i)
    }

    /// Incoming/outgoing unit tangents if the turn at `i` is sharp enough to break the strip.
    /// Turns of exactly ±90° or 180° are skipped: a bridging triangle would have zero area.
    func cornerBreak(at i: Int) -> (Point2, Point2)? {
        guard i > 0, i < points.count - 1 else { return nil }
        let incoming = points[i] - points[i - 1]
        let outgoing = points[i + 1] - points[i]
        let tIn = incoming / dot(incoming, incoming).squareRoot()
        let tOut = outgoing / dot(outgoing, outgoing).squareRoot()
        let cosine = dot(tIn, tOut)
        let sine = cross(tIn, tOut)
        guard cosine < StrokeTessellator.breakCosine, abs(cosine + sine + 1) > 1e-3, abs(cosine - sine + 1) > 1e-3 else { return nil }
        return (tIn, tOut)
    }

    /// Ends the strip with a round cap at `i` and restarts it with one. The bridging triangles between
    /// the caps have `along ≥ radius + fringe`, i.e. zero coverage.
    mutating func cornerCaps(_ i: Int, tIn: Point2, tOut: Point2) {
        let extent = radii[i] + fringe
        let nIn = Point2(-tIn.y, tIn.x)
        let nOut = Point2(-tOut.y, tOut.x)
        pair(points[i], nIn, extent, along: 0, i)
        pair(points[i] + tIn * extent, nIn, extent, along: extent, i)
        pair(points[i] - tOut * extent, nOut, extent, along: extent, i)
        pair(points[i], nOut, extent, along: 0, i)
    }

    /// Body pair at `i`. Inner sides of tight curls fold over, and at the crossing a triangle passes
    /// through zero area; widening the pair slightly (edge.y tracks it, so coverage is unchanged)
    /// steps over it.
    mutating func body(_ i: Int, normal: Point2) {
        var extent = radii[i] + fringe
        let l0 = vertices[vertices.count - 2].position
        let r0 = vertices[vertices.count - 1].position
        for _ in 0 ..< 4 {
            let l = points[i] + normal * extent
            let r = points[i] - normal * extent
            if abs(cross(r0 - l0, l - l0)) > 1e-3, abs(cross(l - r0, r - r0)) > 1e-3 {
                break
            }
            extent *= 1.03
        }
        pair(points[i], normal, extent, along: 0, i)
    }
}
