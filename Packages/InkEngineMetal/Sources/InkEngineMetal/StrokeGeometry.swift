import CoreGraphics
import InkGeometry
import InkModel

/// A stroke's tessellated triangle strip (theme independent), cached by stroke ID.
struct StrokeGeometry: Sendable {
    /// Strip vertices in page space.
    let vertices: [StrokeVertex]
    /// Vertex bounds (with AA fringe).
    let bounds: CGRect
    /// End planes (chisel caps clip against them).
    let ends: StrokeEnds
    /// What the strip was built from; a mismatch means the stroke changed under the same ID.
    let key: Key

    struct Key: Hashable {
        var tool: PenKind
        var width: Float
        var sampleCount: Int
        var bounds: CGRect
        var fringe: Float

        init(_ stroke: Stroke, fringe: Float) {
            tool = stroke.tool
            width = stroke.width
            sampleCount = stroke.samples.count
            bounds = stroke.bounds
            self.fringe = fringe
        }
    }

    /// Tessellates `stroke` (smooth, resample, profile, strip).
    init(_ stroke: Stroke, fringe: Float) {
        let mesh = Self.mesh(samples: stroke.samples, width: stroke.width, kind: stroke.tool, fringe: fringe)
        vertices = mesh.vertices
        bounds = mesh.bounds
        ends = mesh.ends
        key = Key(stroke, fringe: fringe)
    }

    func matches(_ stroke: Stroke, fringe: Float) -> Bool {
        key == Key(stroke, fringe: fringe)
    }

    /// Strip for raw samples (committed or live). Pens: `InkGeometry`'s outline strip. Highlighters:
    /// a chain of capsules (see ``capsuleChain(_:fringe:)``).
    static func mesh(samples: [Sample], width: Float, kind: PenKind, fringe: Float) -> InkMesh {
        let profile = PenProfile(kind)
        if profile.drawsBeneathInk {
            let centerline = Centerline(samples: samples, width: width, profile: profile, spacing: 2)
            if centerline.points.count > 1 {
                let chain = capsuleChain(centerline, fringe: fringe)
                return InkMesh(vertices: chain.vertices, bounds: chain.bounds, ends: StrokeEnds(centerline))
            }
            let mesh = StrokeTessellator.mesh(for: centerline, fringe: fringe)
            return InkMesh(vertices: mesh.vertices, bounds: mesh.bounds, ends: StrokeEnds(centerline))
        }
        let centerline = Centerline(samples: samples, width: width, profile: profile)
        let mesh = StrokeTessellator.mesh(for: centerline, fringe: fringe)
        return InkMesh(vertices: mesh.vertices, bounds: mesh.bounds, ends: StrokeEnds(centerline))
    }

    /// Highlighter strip: one capsule per centerline segment, stitched with degenerate triangles.
    ///
    /// The outline strip folds over itself where a wide, flat-capped stroke turns tighter than its
    /// radius (the highlighter never breaks at corners), leaving notches and holes. Capsules can't
    /// fold, and drawn into the max-blend coverage target they union exactly: round joins at every
    /// turn, no double coverage. The shader squares off the two ends (chisel) against ``StrokeEnds``.
    /// Same `StrokeVertex` semantics as `StrokeTessellator`: per capsule, `edge.x` is the distance
    /// beyond the segment's end, `edge.y` the signed distance from it.
    static func capsuleChain(_ centerline: Centerline, fringe: Float) -> (vertices: [StrokeVertex], bounds: CGRect) {
        let points = centerline.points
        let radii = centerline.radii
        let arcs = centerline.arcLengths
        var vertices: [StrokeVertex] = []
        vertices.reserveCapacity(10 * (points.count - 1))
        var lower = SIMD2<Float>(repeating: .infinity)
        var upper = SIMD2<Float>(repeating: -.infinity)
        for i in 0 ..< points.count - 1 {
            let p0 = points[i]
            let p1 = points[i + 1]
            let d = p1 - p0
            let t = d / (d.x * d.x + d.y * d.y).squareRoot()
            let n = SIMD2<Float>(-t.y, t.x)
            let r = max(radii[i], radii[i + 1])
            let e = r + fringe
            func pair(_ center: SIMD2<Float>, along: Float, arc: Float) {
                let left = center + n * e
                let right = center - n * e
                vertices.append(StrokeVertex(position: left, edge: SIMD2(along, e), radius: r, arcLength: arc))
                vertices.append(StrokeVertex(position: right, edge: SIMD2(along, -e), radius: r, arcLength: arc))
                lower = pointwiseMin(lower, pointwiseMin(left, right))
                upper = pointwiseMax(upper, pointwiseMax(left, right))
            }
            if let last = vertices.last {
                // Degenerate stitch: repeat the previous end and this start.
                vertices.append(last)
                vertices.append(StrokeVertex(position: p0 - t * e + n * e, edge: SIMD2(e, e), radius: r, arcLength: arcs[i]))
            }
            pair(p0 - t * e, along: e, arc: arcs[i])
            pair(p0, along: 0, arc: arcs[i])
            pair(p1, along: 0, arc: arcs[i + 1])
            pair(p1 + t * e, along: e, arc: arcs[i + 1])
        }
        let bounds = CGRect(
            x: CGFloat(lower.x),
            y: CGFloat(lower.y),
            width: CGFloat(upper.x - lower.x),
            height: CGFloat(upper.y - lower.y)
        )
        return (vertices, bounds)
    }
}

/// A tessellated strip with its bounds and end planes.
struct InkMesh {
    var vertices: [StrokeVertex]
    var bounds: CGRect
    var ends: StrokeEnds
}

/// A stroke's two end planes: where it starts (point, inward tangent) and ends (point, outward
/// tangent), plus its centerline length. Chisel-capped strokes are clipped against the planes over
/// the first and last stretch of arc length, which squares off every round cap or capsule that would
/// poke past an end without touching later parts of the stroke that pass nearby.
struct StrokeEnds: Sendable, Equatable {
    /// `(x, y, tx, ty)`: start point and unit tangent into the stroke.
    var start: SIMD4<Float>
    /// `(x, y, tx, ty)`: end point and unit tangent out of the stroke.
    var end: SIMD4<Float>
    /// Centerline length (pt).
    var length: Float

    /// No clipping.
    static let none = StrokeEnds(start: .zero, end: .zero, length: 0)

    init(start: SIMD4<Float>, end: SIMD4<Float>, length: Float) {
        self.start = start
        self.end = end
        self.length = length
    }

    init(_ centerline: Centerline) {
        let p = centerline.points
        guard p.count > 1 else {
            self = .none
            return
        }
        func unit(_ d: SIMD2<Float>) -> SIMD2<Float> {
            d / (d.x * d.x + d.y * d.y).squareRoot()
        }
        let t0 = unit(p[1] - p[0])
        let t1 = unit(p[p.count - 1] - p[p.count - 2])
        start = SIMD4(p[0].x, p[0].y, t0.x, t0.y)
        end = SIMD4(p[p.count - 1].x, p[p.count - 1].y, t1.x, t1.y)
        length = centerline.length
    }
}
