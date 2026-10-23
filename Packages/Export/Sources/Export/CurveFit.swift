import InkGeometry

/// A path as one start point plus cubic Bézier (or straight) segments, page space: a closed outline contour
/// (``CurveFit/fit(closed:tolerance:)``) or an open centerline (``CurveFit/fit(open:tolerance:)``).
struct CubicContour: Sendable {
    /// One segment: two control points and the end point (the start is the previous segment's end).
    struct Segment: Sendable {
        var c1: Point2
        var c2: Point2
        var end: Point2
        /// The points are straight here within tolerance: draw a line (control points unused).
        var isLine = false
    }

    var start: Point2
    var segments: [Segment]
}

/// Fits cubic Béziers to dense polylines (Schneider, "An Algorithm for Automatically Fitting Digitized
/// Curves", Graphics Gems 1990, with greedy runs), so PDF ink is a handful of curves instead of hundreds
/// of points.
///
/// `StrokeOutline` contours and `Centerline`s are dense (~1 pt) polylines sampled from smooth curves, so
/// a few cubics reproduce them within the tolerance; corners sharper than ``cornerCosine`` (flat
/// highlighter caps, join cuts, cusps) are kept as segment boundaries.
enum CurveFit {
    /// Default maximum distance (pt) between the fitted curves and the points. ``StrokeShape`` passes a
    /// width-relative one instead.
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

    /// Fits one open polyline (a centerline), splitting at turns sharper than ``cornerCosine``. `nil` for
    /// fewer than 2 distinct points.
    static func fit(open polyline: [Point2], tolerance: Float = tolerance) -> CubicContour? {
        let pts = dedupe(polyline, closed: false)
        let n = pts.count
        guard n >= 2 else { return nil }
        var breaks = [0]
        for i in 1 ..< n - 1 where dot(unit(pts[i] - pts[i - 1]), unit(pts[i + 1] - pts[i])) < cornerCosine {
            breaks.append(i)
        }
        breaks.append(n - 1)
        var fitter = Fitter(d: pts, error2: tolerance * tolerance)
        for (a, b) in zip(breaks, breaks.dropFirst()) {
            fitter.fit(a ... b, endTangent(pts, from: a, toward: b), endTangent(pts, from: b, toward: a))
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

    /// Fitter over one polyline `d`; appends to ``out``.
    ///
    /// Greedy rather than Schneider's split-at-worst-point recursion: from each start it takes the longest
    /// run one cubic fits (gallop, then bisect), which needs ~20 % fewer segments. Segments whose points all
    /// lie within tolerance of the chord become lines (2 PDF coordinates instead of 6).
    private struct Fitter {
        /// Newton reparameterization passes per candidate cubic.
        static let iterations = 20
        /// Candidates whose first error exceeds this many squared tolerances aren't worth iterating.
        static let iterationLimit: Float = 1000

        let d: [Point2]
        /// Squared tolerance.
        let error2: Float
        var out: [CubicContour.Segment] = []

        mutating func fit(_ run: ClosedRange<Int>, _ tHat1: Point2, _ tHat2: Point2) {
            var a = run.lowerBound
            let last = run.upperBound
            var tA = tHat1
            while a < last {
                if let b = single(a ... last, tA, tHat2) {
                    append(b, a ... last)
                    return
                }
                // a ... a + 1 always fits; a ... last doesn't.
                var lo = a + 1
                var best = single(a ... lo, tA, center(lo))
                var hi = last
                var step = 4
                while lo + step < hi, let b = single(a ... lo + step, tA, center(lo + step)) {
                    lo += step
                    best = b
                    step *= 2
                }
                hi = min(hi, lo + step)
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if let b = single(a ... mid, tA, center(mid)) {
                        lo = mid
                        best = b
                    } else {
                        hi = mid
                    }
                }
                if let best {
                    append(best, a ... lo)
                }
                tA = -center(lo)
                a = lo
            }
        }

        /// One cubic through the run's end points with the given end tangents, within tolerance, or `nil`.
        private func single(_ run: ClosedRange<Int>, _ tHat1: Point2, _ tHat2: Point2) -> Bezier? {
            let (first, last) = (run.lowerBound, run.upperBound)
            if run.count == 2 {
                let dist = norm(d[last] - d[first]) / 3
                return Bezier(p0: d[first], p1: d[first] + tHat1 * dist, p2: d[last] + tHat2 * dist, p3: d[last])
            }
            var u = chordLengthParameterize(run)
            var bezier = generateBezier(run, u, tHat1, tHat2)
            var maxError = maxError(run, bezier, u)
            var iterations = maxError < error2 * Self.iterationLimit ? Self.iterations : 0
            while maxError >= error2, iterations > 0 {
                for i in u.indices {
                    u[i] = bezier.newtonRaphson(d[first + i], u[i])
                }
                bezier = generateBezier(run, u, tHat1, tHat2)
                maxError = self.maxError(run, bezier, u)
                iterations -= 1
            }
            return maxError < error2 ? bezier : nil
        }

        /// Appends `b`, as a line if the run's points all lie within tolerance of its chord.
        private mutating func append(_ b: Bezier, _ run: ClosedRange<Int>) {
            let v = b.p3 - b.p0
            let len2 = dot(v, v)
            var isLine = true
            for i in run.dropFirst().dropLast() where isLine {
                let w = d[i] - b.p0
                let t = len2 > 0 ? min(max(dot(w, v) / len2, 0), 1) : 0
                let e = w - v * t
                isLine = dot(e, e) < error2
            }
            out.append(.init(c1: b.p1, c2: b.p2, end: b.p3, isLine: isLine))
        }

        /// Smooth tangent at interior point `i`, pointing backwards (into a run ending at `i`).
        private func center(_ i: Int) -> Point2 {
            unit(d[i - 1] - d[i + 1])
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

        /// Largest squared distance from an interior point to the curve (at its parameter).
        private func maxError(_ run: ClosedRange<Int>, _ bezier: Bezier, _ u: [Float]) -> Float {
            var maxDist: Float = 0
            for i in run.lowerBound + 1 ..< run.upperBound {
                let v = bezier.evaluate(u[i - run.lowerBound]) - d[i]
                maxDist = max(maxDist, dot(v, v))
            }
            return maxDist
        }
    }

    // MARK: Helpers

    private static func dedupe(_ polygon: [Point2], closed: Bool = true) -> [Point2] {
        var out: [Point2] = []
        out.reserveCapacity(polygon.count)
        for p in polygon where p.x.isFinite && p.y.isFinite {
            if let last = out.last, norm(p - last) < 1e-3 {
                continue
            }
            out.append(p)
        }
        while closed, out.count > 1, let first = out.first, let last = out.last, norm(first - last) < 1e-3 {
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

    /// Unit tangent at run end `i` pointing into the run (towards `j`): second-order one-sided difference
    /// when the run has 3+ points, so curved ends aren't biased towards the chord.
    private static func endTangent(_ pts: [Point2], from i: Int, toward j: Int) -> Point2 {
        let step = j > i ? 1 : -1
        let chord = unit(pts[i + step] - pts[i])
        guard abs(j - i) >= 2 else { return chord }
        let t = unit(4 * pts[i + step] - pts[i + 2 * step] - 3 * pts[i])
        // A cusp right at the end can flip the estimate; keep the chord then.
        return dot(t, chord) > 0.5 ? t : chord
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
