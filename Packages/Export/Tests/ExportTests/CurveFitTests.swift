@testable import Export
import InkGeometry
import InkModel
import Testing

struct CurveFitTests {
    /// Dense samples along the fitted path; closed paths leave out the final end point (it's the start).
    private func flatten(_ contour: CubicContour, closed: Bool = true) -> [Point2] {
        var out: [Point2] = []
        var p0 = contour.start
        for s in contour.segments {
            for k in 0 ..< 32 {
                let t = Float(k) / 32
                let mt = 1 - t
                out.append(
                    s.isLine
                        ? p0 + (s.end - p0) * t
                        : p0 * (mt * mt * mt) + s.c1 * (3 * mt * mt * t) + s.c2 * (3 * mt * t * t) + s.end * (t * t * t)
                )
            }
            p0 = s.end
        }
        if !closed {
            out.append(p0)
        }
        return out
    }

    private func distance(_ p: Point2, to curve: [Point2], closed: Bool = true) -> Float {
        var best = Float.infinity
        for (a, b) in zip(curve, curve.dropFirst() + (closed ? [curve[0]] : [])) {
            let ab = b - a
            let len2 = (ab * ab).sum()
            let u = len2 > 0 ? min(max(((p - a) * ab).sum() / len2, 0), 1) : 0
            let d = p - (a + ab * u)
            best = min(best, (d * d).sum().squareRoot())
        }
        return best
    }

    @Test(arguments: 0 ..< 40)
    func fitStaysWithinToleranceOfOutline(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let tool = PenKind.allCases[Int(seed) % PenKind.allCases.count]
        let stroke = Fixtures.handwriting(&rng, tool: tool)
        let contours = StrokeOutline(stroke: stroke).contours
        #expect(!contours.isEmpty)
        var points = 0
        var segments = 0
        for polygon in contours {
            let fitted = try #require(CurveFit.fit(closed: polygon))
            let curve = flatten(fitted)
            for p in polygon {
                #expect(distance(p, to: curve) <= CurveFit.tolerance * 1.1 + 0.01)
            }
            points += polygon.count
            segments += fitted.segments.count
        }
        // Curves are the point of the exercise: far fewer coordinates than the polygon.
        #expect(segments * 3 < points)
    }

    @Test func keepsCorners() throws {
        let square: [Point2] = (0 ..< 40).map { Point2(Float($0), 0) } + (0 ..< 40).map { Point2(40, Float($0)) }
            + (0 ..< 40).map { Point2(40 - Float($0), 40) } + (0 ..< 40).map { Point2(0, 40 - Float($0)) }
        let fitted = try #require(CurveFit.fit(closed: square))
        let ends = [fitted.start] + fitted.segments.map(\.end)
        for corner in [Point2(0, 0), Point2(40, 0), Point2(40, 40), Point2(0, 40)] {
            #expect(ends.contains(corner))
        }
        #expect(fitted.segments.count == 4)
        let allLines = fitted.segments.allSatisfy(\.isLine)
        #expect(allLines)
    }

    @Test(arguments: 0 ..< 40)
    func openFitStaysWithinToleranceOfCenterline(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let tool = PenKind.allCases[Int(seed) % PenKind.allCases.count]
        let centerline = Centerline(stroke: Fixtures.handwriting(&rng, tool: tool))
        let tolerance: Float = 0.05
        let fitted = try #require(CurveFit.fit(open: centerline.points, tolerance: tolerance))
        #expect(fitted.start == centerline.points.first)
        #expect(fitted.segments.last?.end == centerline.points.last)
        let curve = flatten(fitted, closed: false)
        for p in centerline.points {
            #expect(distance(p, to: curve, closed: false) <= tolerance * 1.1 + 0.01)
        }
        #expect(fitted.segments.count * 3 < centerline.points.count)
    }

    @Test func openFitKeepsCuspsAndStraightRuns() throws {
        // A V: 30 pt down-right, then 30 pt up-right.
        let v = (0 ... 30).map { Point2(Float($0), Float($0)) } + (1 ... 30).map { Point2(30 + Float($0), 30 - Float($0)) }
        let fitted = try #require(CurveFit.fit(open: v, tolerance: 0.05))
        #expect(fitted.segments.map(\.end) == [Point2(30, 30), Point2(60, 0)])
        let allLines = fitted.segments.allSatisfy(\.isLine)
        #expect(allLines)
    }

    @Test func degenerateInput() {
        #expect(CurveFit.fit(closed: []) == nil)
        #expect(CurveFit.fit(closed: [Point2(1, 1), Point2(1, 1), Point2(2, 2)]) == nil)
        #expect(CurveFit.fit(closed: [Point2(0, 0), Point2(1, 0), Point2(0, 1)]) != nil)
        #expect(CurveFit.fit(open: []) == nil)
        #expect(CurveFit.fit(open: [Point2(1, 1), Point2(1, 1)]) == nil)
        #expect(CurveFit.fit(open: [Point2(0, 0), Point2(1, 0)])?.segments.count == 1)
    }
}
