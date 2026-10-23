import CoreGraphics
import Foundation
import InkGeometry
import InkModel
import Testing

/// Nonzero winding number of `p` around closed polygons.
private func winding(_ contours: [[Point2]], _ p: Point2) -> Int {
    contours.reduce(0) { $0 + winding($1, p) }
}

private func winding(_ polygon: [Point2], _ p: Point2) -> Int {
    var w = 0
    for i in polygon.indices {
        let a = polygon[i]
        let b = polygon[(i + 1) % polygon.count]
        let side = doubleArea(a, b, p)
        if a.y <= p.y {
            if b.y > p.y, side > 0 {
                w += 1
            }
        } else if b.y <= p.y, side < 0 {
            w -= 1
        }
    }
    return w
}

/// Signed distance from `p` to the capsule chain (negative inside).
private func capsuleDistance(_ c: Centerline, _ p: Point2) -> Float {
    if c.points.count == 1 {
        return ((p - c.points[0]) * (p - c.points[0])).sum().squareRoot() - c.radii[0]
    }
    var best = Float.infinity
    for i in 0 ..< c.points.count - 1 {
        let (d, u) = segmentDistance(p, c.points[i], c.points[i + 1])
        best = min(best, d - (c.radii[i] + (c.radii[i + 1] - c.radii[i]) * u))
    }
    return best
}

/// Signed distance from `p` to the union of discs swept along the centerline (center and radius
/// interpolated linearly per segment), sampled finely. Negative inside.
private func sweptDistance(_ c: Centerline, _ p: Point2) -> Float {
    var best = ((p - c.points[0]) * (p - c.points[0])).sum().squareRoot() - c.radii[0]
    for i in 0 ..< max(c.points.count - 1, 0) {
        // Lower bound: nothing on this segment can beat `best`.
        guard segmentDistance(p, c.points[i], c.points[i + 1]).distance - max(c.radii[i], c.radii[i + 1]) < best else { continue }
        for k in 1 ... 32 {
            let u = Float(k) / 32
            let q = c.points[i] + (c.points[i + 1] - c.points[i]) * u
            best = min(best, ((p - q) * (p - q)).sum().squareRoot() - (c.radii[i] + (c.radii[i + 1] - c.radii[i]) * u))
        }
    }
    return best
}

struct OutlineTests {
    /// The contours filled nonzero match the swept-disc shape away from the edge (no holes, no blobs).
    @Test(arguments: 0 ..< 40)
    func nonzeroFillMatchesShape(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let stroke = Fixtures.handwriting(
            &rng,
            count: Int.random(in: 1 ... 40, using: &rng),
            tool: seed.isMultiple(of: 5) ? .highlighter : .fountain
        )
        let centerline = Centerline(stroke: stroke)
        let outline = StrokeOutline(centerline: centerline)
        #expect(outline.contours.joined().allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let b = outline.bounds
        #expect(centerline.bounds.insetBy(dx: -1e-3, dy: -1e-3).contains(b) || centerline.capStyle == .butt)
        let maxRadius = centerline.radii.max() ?? 0
        var mismatches = 0
        var worst: Float = 0
        var checked = 0
        for _ in 0 ..< 250 {
            let p = Point2(
                Float.random(in: Float(b.minX) ... Float(b.maxX), using: &rng),
                Float.random(in: Float(b.minY) ... Float(b.maxY), using: &rng)
            )
            let d = sweptDistance(centerline, p)
            // Skip the boundary band (polygonized arcs/tapers deviate < 0.45 pt worst case) and butt-capped ends (the capsule model rounds
            // them).
            guard abs(d) > 0.45 else { continue }
            if centerline.capStyle == .butt {
                let ends = [centerline.points[0], centerline.points[centerline.points.count - 1]]
                if ends.contains(where: { ((p - $0) * (p - $0)).sum().squareRoot() < maxRadius + 0.5 }) {
                    continue
                }
            }
            checked += 1
            if (d < 0) != (winding(outline.contours, p) != 0) {
                mismatches += 1; worst = abs(d) > abs(worst) ? d : worst
            }
        }
        #expect(mismatches == 0, "seed \(seed): \(mismatches)/\(checked), worst \(worst) pt")
    }

    @Test func dotIsACircle() {
        let outline = StrokeOutline(stroke: Stroke(tool: .ballpoint, color: .primary, width: 4, samples: [Sample(x: 10, y: 10)]))
        let c = Centerline(stroke: Stroke(tool: .ballpoint, color: .primary, width: 4, samples: [Sample(x: 10, y: 10)]))
        #expect(outline.contours.count == 1)
        for p in outline.contours[0] {
            let r = ((p - Point2(10, 10)) * (p - Point2(10, 10))).sum().squareRoot()
            #expect(abs(r - c.radii[0]) < 1e-4)
        }
        #expect(outline.pointCount >= 6)
        #expect(StrokeOutline(stroke: Stroke(tool: .ballpoint, color: .primary, width: 4, samples: [])).contours.isEmpty)
    }

    @Test func buttCapsAreFlat() {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 2, tool: .highlighter, width: 6)
        let outline = StrokeOutline(stroke: stroke)
        #expect(outline.contours.count == 1 && outline.pointCount == 22)
        #expect(outline.bounds == CGRect(x: 0, y: -3, width: 10, height: 6))
    }
}

struct CircleHitTests {
    @Test(arguments: 0 ..< 100)
    func matchesBruteForce(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let stroke = Fixtures.handwriting(&rng, count: Int.random(in: 1 ... 60, using: &rng), tool: .fountain)
        let centerline = Centerline(stroke: stroke)
        let b = stroke.bounds.insetBy(dx: -10, dy: -10)
        for _ in 0 ..< 50 {
            let center = CGPoint(x: .random(in: b.minX ... b.maxX, using: &rng), y: .random(in: b.minY ... b.maxY, using: &rng))
            let radius = CGFloat.random(in: 0.5 ... 12, using: &rng)
            let d = capsuleDistance(centerline, Point2(center)) - Float(radius)
            guard abs(d) > 1e-3 else { continue }
            #expect(stroke.intersects(circleCenter: center, radius: radius) == (d <= 0))
        }
    }

    @Test func edgeCases() {
        let line = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 2)
        let c = Centerline(stroke: line)
        let r = c.radii[0]
        #expect(c.intersects(circleCenter: Point2(5, r + 0.9), radius: 1))
        #expect(!c.intersects(circleCenter: Point2(5, r + 1.1), radius: 1))
        #expect(!c.intersects(circleCenter: Point2(5, 0), radius: .nan))
        #expect(!line.intersects(circleCenter: CGPoint(x: 500, y: 500), radius: 5))
        let dot = Centerline(samples: [Sample(x: 0, y: 0)], width: 2, profile: .ballpoint)
        #expect(dot.intersects(circleCenter: Point2(1.5, 0), radius: 1))
        #expect(!dot.intersects(circleCenter: Point2(3, 0), radius: 1))
        #expect(!Centerline(samples: [], width: 2, profile: .ballpoint).intersects(circleCenter: .zero, radius: 5))
    }
}

struct LassoTests {
    let square = Lasso([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])

    @Test func pointInPolygon() {
        #expect(square.contains(CGPoint(x: 5, y: 5)))
        #expect(!square.contains(CGPoint(x: 15, y: 5)))
        #expect(!square.contains(Point2(5, -1)))
        // Concave "C" shape: the notch is outside.
        let c = Lasso(points: [
            Point2(0, 0),
            Point2(10, 0),
            Point2(10, 3),
            Point2(3, 3),
            Point2(3, 7),
            Point2(10, 7),
            Point2(10, 10),
            Point2(0, 10),
        ])
        #expect(c.contains(Point2(1, 5)) && !c.contains(Point2(6, 5)) && c.contains(Point2(6, 1)))
        // Self-intersecting bow-tie, even-odd.
        let bow = Lasso(points: [Point2(0, 0), Point2(10, 10), Point2(10, 0), Point2(0, 10)])
        #expect(bow.contains(Point2(2, 5)) && !bow.contains(Point2(5, 2)))
        #expect(!Lasso(points: [Point2(0, 0), Point2(1, 1)]).contains(Point2(0.5, 0.5)))
        let filtered = Lasso(points: [Point2(0, 0), Point2(.nan, 1), Point2(4, 0), Point2(0, 4)])
        #expect(filtered.points.count == 3 && filtered.contains(Point2(1, 1)))
    }

    @Test func selectsByHalfTheSamples() {
        let half = Fixtures.line(from: Point2(5, 5), to: Point2(15, 5), samples: 4) // 2 of 4 inside
        let third = Fixtures.line(from: Point2(5, 5), to: Point2(25, 5), samples: 6) // 2 of 6
        let all = Fixtures.line(from: Point2(2, 2), to: Point2(8, 8), samples: 5)
        let far = Fixtures.line(from: Point2(50, 50), to: Point2(60, 60), samples: 3)
        let empty = Stroke(tool: .fountain, color: .primary, width: 2, samples: [])
        #expect(square.insideFraction(of: half) == 0.5)
        #expect(square.selects(half) && !square.selects(third) && square.selects(all) && !square.selects(far) && !square.selects(empty))
        #expect(square.selects(third, threshold: 0.3))
        #expect(square.selection(from: [far, half, third, all]) == [half.id, all.id])
    }

    /// Lasso + index prefilter gives the same selection as a full scan.
    @Test(arguments: 0 ..< 10)
    func prefilterMatchesScan(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let strokes = (0 ..< 150).map { _ in Fixtures.handwriting(&rng, count: 20) }
        let lasso = Lasso(points: (0 ..< 24).map { i in
            let a = Float(i) / 24 * 2 * .pi
            let r = Float.random(in: 80 ... 220, using: &rng)
            return Point2(300, 420) + r * Point2(cos(a), sin(a))
        })
        let index = StrokeIndex(strokes: strokes)
        let candidates = Set(index.query(lasso.bounds))
        let viaIndex = lasso.selection(from: strokes.filter { candidates.contains($0.id) })
        #expect(viaIndex == lasso.selection(from: strokes))
    }
}
