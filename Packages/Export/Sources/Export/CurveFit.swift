import InkGeometry

/// A closed outline as one start point plus cubic Bézier segments, page space.
struct CubicContour: Sendable {
    /// One segment: two control points and the end point (the start is the previous segment's end).
    struct Segment: Sendable {
        var c1: Point2
        var c2: Point2
        var end: Point2
    }

    var start: Point2
    var segments: [Segment]
}

/// Fits cubic Béziers to closed outline polygons (Schneider, "An Algorithm for Automatically Fitting
/// Digitized Curves", Graphics Gems 1990), so PDF ink is a handful of curves instead of hundreds of points.
///
/// `StrokeOutline` contours are dense (~1 pt) polygons sampled from smooth offset curves, so a few cubics
/// per side reproduce them within ``tolerance``; corners sharper than ``cornerCosine`` (flat highlighter
/// caps, join cuts) are kept as segment boundaries.
enum CurveFit {
    /// Maximum distance (pt) between the fitted curves and the outline's points. 0.15 pt (~0.05 mm, ~0.6 px
    /// at 300 dpi) keeps the 100-page budget under 10 MB; 0.1 pt costs ~18 % more.
    static let tolerance: Float = 0.15
    /// Turns sharper than ~50° split the contour.
    static let cornerCosine: Float = 0.64

    /// Fits one closed contour. `nil` for fewer than 3 distinct points.
    static func fit(closed polygon: [Point2], tolerance: Float = tolerance) -> CubicContour? {
        var pts = dedupe(polygon)
        guard pts.count >= 3 else { return nil }
        // Rotate so the contour starts at a corner if it has one; otherwise anywhere.
        let corners = cornerIndices(pts)
        if let first = corners.first, first != 0 {
            pts = Array(pts[first...] + pts[..<first])
        }
        pts.append(pts[0]) // close
        let n = pts.count
        let cornerSet = Set(cornerIndices(Array(pts.dropLast())))
        var breaks = [0] + (1 ..< n - 1).filter { cornerSet.contains($0) } + [n - 1]
        if breaks.count == 2 {
            // Smooth closed loop: split in two so each run has distinct end points and tangents.
            breaks = [0, n / 2, n - 1]
        }

        var fitter = Fitter(d: pts, error2: tolerance * tolerance)
        for (a, b) in zip(breaks, breaks.dropFirst()) where b > a {
            let isSmoothStart = !cornerSet.contains(a % (n - 1))
            let isSmoothEnd = !cornerSet.contains(b % (n - 1))
            let t1 = isSmoothStart ? smoothTangent(pts, at: a, forward: true) : unit(pts[a + 1] - pts[a])
            let t2 = isSmoothEnd ? smoothTangent(pts, at: b, forward: false) : unit(pts[b - 1] - pts[b])
            fitter.fit(a ... b, t1, t2)
        }
        return CubicContour(start: pts[0], segments: fitter.out)
    }

    // MARK: Schneider

    private struct Bezier {
        var p0: Point2
        var p1: Point2
        var p2: Point2
        var p3: Point2

        func evaluate(_ t: Float) -> Point2 {
            let mt = 1 - t
            return p0 * (mt * mt * mt) + p1 * (3 * mt * mt * t) + p2 * (3 * mt * t * t) + p3 * (t * t * t)
        }

        /// One Newton step towards the parameter of the point on the curve closest to `p`.
        func newtonRaphson(_ p: Point2, _ u: Float) -> Float {
            let d1 = 3 * ((p1 - p0) * (1 - u) * (1 - u) + (p2 - p1) * 2 * u * (1 - u) + (p3 - p2) * u * u)
            let d2 = 6 * ((p2 - 2 * p1 + p0) * (1 - u) + (p3 - 2 * p2 + p1) * u)
            let diff = evaluate(u) - p
            let denominator = dot(d1, d1) + dot(diff, d2)
            guard abs(denominator) > 1e-12 else { return u }
            let next = u - dot(diff, d1) / denominator
            return next.isFinite ? min(max(next, 0), 1) : u
        }
    }

    /// Recursive fitter over one closed polygon `d`; appends to ``out``.
    private struct Fitter {
        let d: [Point2]
        /// Squared tolerance.
        let error2: Float
        var out: [CubicContour.Segment] = []

        mutating func fit(_ run: ClosedRange<Int>, _ tHat1: Point2, _ tHat2: Point2) {
            let (first, last) = (run.lowerBound, run.upperBound)
            if run.count == 2 {
                let dist = norm(d[last] - d[first]) / 3
                out.append(.init(c1: d[first] + tHat1 * dist, c2: d[last] + tHat2 * dist, end: d[last]))
                return
            }
            var u = chordLengthParameterize(run)
            var bezier = generateBezier(run, u, tHat1, tHat2)
            var (maxError, split) = maxError(run, bezier, u)
            var iterations = maxError < error2 * 16 ? 4 : 0
            while maxError >= error2, iterations > 0 {
                u = u.enumerated().map { i, t in bezier.newtonRaphson(d[first + i], t) }
                bezier = generateBezier(run, u, tHat1, tHat2)
                (maxError, split) = self.maxError(run, bezier, u)
                iterations -= 1
            }
            if maxError < error2 {
                out.append(.init(c1: bezier.p1, c2: bezier.p2, end: bezier.p3))
                return
            }
            let center = unit(d[split - 1] - d[split + 1])
            fit(first ... split, tHat1, center)
            fit(split ... last, -center, tHat2)
        }

        /// Least-squares control points for fixed end tangents.
        private func generateBezier(_ run: ClosedRange<Int>, _ u: [Float], _ tHat1: Point2, _ tHat2: Point2) -> Bezier {
            var c00: Float = 0, c01: Float = 0, c11: Float = 0, x0: Float = 0, x1: Float = 0
            let p0 = d[run.lowerBound], p3 = d[run.upperBound]
            for (i, t) in u.enumerated() {
                let mt = 1 - t
                let b0 = mt * mt * mt, b1 = 3 * t * mt * mt, b2 = 3 * t * t * mt, b3 = t * t * t
                let a1 = tHat1 * b1, a2 = tHat2 * b2
                c00 += dot(a1, a1)
                c01 += dot(a1, a2)
                c11 += dot(a2, a2)
                let tmp = d[run.lowerBound + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
                x0 += dot(a1, tmp)
                x1 += dot(a2, tmp)
            }
            let det = c00 * c11 - c01 * c01
            var alphaL: Float = 0, alphaR: Float = 0
            if abs(det) > 1e-12 {
                alphaL = (x0 * c11 - x1 * c01) / det
                alphaR = (c00 * x1 - c01 * x0) / det
            }
            let segLength = norm(p3 - p0)
            let epsilon = 1e-6 * segLength
            if alphaL < epsilon || alphaR < epsilon || !alphaL.isFinite || !alphaR.isFinite {
                // Degenerate solve: Wu/Barsky heuristic.
                let dist = segLength / 3
                return Bezier(p0: p0, p1: p0 + tHat1 * dist, p2: p3 + tHat2 * dist, p3: p3)
            }
            return Bezier(p0: p0, p1: p0 + tHat1 * alphaL, p2: p3 + tHat2 * alphaR, p3: p3)
        }

        private func chordLengthParameterize(_ run: ClosedRange<Int>) -> [Float] {
            var u: [Float] = [0]
            u.reserveCapacity(run.count)
            for i in run.dropFirst() {
                u.append(u[u.count - 1] + norm(d[i] - d[i - 1]))
            }
            let total = u[u.count - 1]
            return total > 0 ? u.map { $0 / total } : u
        }

        /// Largest squared distance from an interior point to the curve, and where.
        private func maxError(_ run: ClosedRange<Int>, _ bezier: Bezier, _ u: [Float]) -> (Float, Int) {
            var maxDist: Float = 0
            var split = (run.lowerBound + run.upperBound) / 2
            for i in run.lowerBound + 1 ..< run.upperBound {
                let v = bezier.evaluate(u[i - run.lowerBound]) - d[i]
                let dist = dot(v, v)
                if dist >= maxDist {
                    maxDist = dist
                    split = i
                }
            }
            return (maxDist, split)
        }
    }

    // MARK: Helpers

    private static func dedupe(_ polygon: [Point2]) -> [Point2] {
        var out: [Point2] = []
        out.reserveCapacity(polygon.count)
        for p in polygon where p.x.isFinite && p.y.isFinite {
            if let last = out.last, norm(p - last) < 1e-3 {
                continue
            }
            out.append(p)
        }
        while out.count > 1, let first = out.first, let last = out.last, norm(first - last) < 1e-3 {
            out.removeLast()
        }
        return out
    }

    /// Indices where the closed polygon turns sharper than ``cornerCosine``.
    private static func cornerIndices(_ pts: [Point2]) -> [Int] {
        let n = pts.count
        return (0 ..< n).filter { i in
            let a = unit(pts[i] - pts[(i + n - 1) % n])
            let b = unit(pts[(i + 1) % n] - pts[i])
            return dot(a, b) < cornerCosine
        }
    }

    /// Unit tangent at `i` from its neighbors (pointing into the run when `forward`, out of it otherwise).
    private static func smoothTangent(_ pts: [Point2], at i: Int, forward: Bool) -> Point2 {
        let n = pts.count - 1 // pts is closed (last == first)
        let prev = pts[(i + n - 1) % n]
        let next = pts[(i + 1) % n]
        let t = unit(next - prev)
        return forward ? t : -t
    }

    private static func unit(_ v: Point2) -> Point2 {
        let l = norm(v)
        return l > 0 ? v / l : Point2(1, 0)
    }

    private static func norm(_ v: Point2) -> Float {
        dot(v, v).squareRoot()
    }

    private static func dot(_ a: Point2, _ b: Point2) -> Float {
        a.x * b.x + a.y * b.y
    }
}
