import Foundation
@testable import InkGeometry
import Testing

/// Hold-to-snap shapes (#165): freehand-like strokes (wobble, overshoot, rounded corners) snap to the
/// shape they were meant to be; open curves and scribbles don't snap.
struct ShapeRecognizerTests {
    /// Deterministic wobble: a smooth-ish random walk across the path, `amount` pt at most.
    private struct Wobble {
        var state: UInt64
        var offset: Float = 0

        mutating func next(_ amount: Float) -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let r = Float(state >> 40) / Float(1 << 24) * 2 - 1
            offset = min(max(offset * 0.8 + r * amount * 0.4, -amount), amount)
            return offset
        }
    }

    /// `points` densified to ~1 pt apart, each pushed across the path by a wobble of up to `amount` pt.
    private static func drawn(_ points: [Point2], wobble amount: Float, seed: UInt64 = 7) -> [Point2] {
        var wobble = Wobble(state: seed)
        var out: [Point2] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let d = b - a
            let length = norm(d)
            guard length > 0 else { continue }
            let normal = Point2(-d.y, d.x) / length
            for i in 0 ..< max(Int(length), 1) {
                out.append(a + d * (Float(i) / max(length.rounded(.down), 1)) + normal * wobble.next(amount))
            }
        }
        return out + (points.last.map { [$0] } ?? [])
    }

    private static func circle(center: Point2, radius: Point2, from: Float = 0, sweep: Float = 2 * .pi, rotation: Float = 0)
        -> [Point2]
    {
        (0 ... 200).map { i in
            let t = from + sweep * Float(i) / 200
            let p = Point2(radius.x * cos(t), radius.y * sin(t))
            return center + Point2(p.x * cos(rotation) - p.y * sin(rotation), p.x * sin(rotation) + p.y * cos(rotation))
        }
    }

    /// The corners joined from just past the first one around back to it and `overshoot` pt beyond, each
    /// corner cut by a small arc (a drawn corner is never sharp).
    private static func polygon(_ corners: [Point2], closing overshoot: Float = 0, rounding: Float = 4) -> [Point2] {
        let cut = { (i: Int) -> (into: Point2, out: Point2) in
            let (prev, c, next) = (corners[(i + corners.count - 1) % corners.count], corners[i], corners[(i + 1) % corners.count])
            return (c - (c - prev) / norm(c - prev) * rounding, c + (next - c) / norm(next - c) * rounding)
        }
        let first = cut(0)
        let around = corners.indices.dropFirst().flatMap { [cut($0).into, cut($0).out] }
        let past = corners[0] + (first.out - corners[0]) * ((rounding + overshoot) / rounding)
        return [first.out] + around + [first.into, past]
    }

    private static func near(_ a: Point2, _ b: Point2, within tolerance: Float = 4) -> Bool {
        norm(a - b) <= tolerance
    }

    @Test func nearlyStraightStrokeIsALine() throws {
        let points = Self.drawn([Point2(100, 100), Point2(400, 130)], wobble: 3)
        let shape = try #require(ShapeRecognizer.recognize(points))
        guard case let .line(a, b) = shape else { Issue.record("not a line: \(shape)"); return }
        #expect(a == points[0], "a line starts where the stroke did")
        #expect(abs(norm(b - a) - norm(points[points.count - 1] - points[0])) < 0.01)
    }

    @Test func lineAngleSnapsToWhole45s() throws {
        let level = try #require(ShapeRecognizer.recognize(Self.drawn([Point2(100, 100), Point2(400, 120)], wobble: 1)))
        guard case let .line(a, b) = level else { Issue.record("not a line"); return }
        #expect(abs(b.y - a.y) < 1e-3, "3.8° off level snaps level")
        let diagonal = try #require(ShapeRecognizer.recognize(Self.drawn([Point2(100, 100), Point2(300, 320)], wobble: 1)))
        guard case let .line(c, d) = diagonal else { Issue.record("not a line"); return }
        #expect(abs((d.y - c.y) - (d.x - c.x)) < 1e-2, "2.7° off 45° snaps to 45°")
        let free = try #require(ShapeRecognizer.recognize(Self.drawn([Point2(100, 100), Point2(400, 220)], wobble: 1)))
        guard case let .line(e, f) = free else { Issue.record("not a line"); return }
        #expect(abs(atan2(f.y - e.y, f.x - e.x) - atan2(120, 300)) < 0.02, "21.8° stays")
    }

    @Test func roundLoopIsACircle() throws {
        let points = Self.drawn(Self.circle(center: Point2(300, 300), radius: Point2(100, 92), sweep: 2 * .pi + 0.3), wobble: 3)
        let shape = try #require(ShapeRecognizer.recognize(points))
        guard case let .ellipse(center, radii, _) = shape else { Issue.record("not an ellipse: \(shape)"); return }
        #expect(Self.near(center, Point2(300, 300), within: 6))
        #expect(radii.x == radii.y, "near-round snaps to a circle")
        #expect(abs(radii.x - 96) < 6)
    }

    @Test func ovalIsAnEllipseWithSnappedAxis() throws {
        let points = Self.drawn(
            Self.circle(center: Point2(300, 300), radius: Point2(160, 70), from: 1, sweep: 2 * .pi - 0.15, rotation: 0.06),
            wobble: 2
        )
        let shape = try #require(ShapeRecognizer.recognize(points))
        guard case let .ellipse(center, radii, rotation) = shape else { Issue.record("not an ellipse: \(shape)"); return }
        #expect(Self.near(center, Point2(300, 300), within: 8))
        #expect(abs(radii.x - 160) < 10 && abs(radii.y - 70) < 10)
        #expect(abs(sin(rotation)) < 1e-4, "3.4° off level snaps level")
    }

    @Test func tiltedOvalKeepsItsAngle() throws {
        let points = Self.drawn(Self.circle(center: Point2(300, 300), radius: Point2(150, 60), rotation: 0.4), wobble: 2)
        let shape = try #require(ShapeRecognizer.recognize(points))
        guard case let .ellipse(_, radii, rotation) = shape else { Issue.record("not an ellipse: \(shape)"); return }
        #expect(radii.x > radii.y)
        #expect(abs(sin(rotation - 0.4)) < 0.05)
    }

    @Test func roughRectangleIsARectangle() throws {
        let corners = [Point2(100, 100), Point2(400, 104), Point2(397, 300), Point2(102, 296)]
        let shape = try #require(ShapeRecognizer.recognize(Self.drawn(Self.polygon(corners, closing: 12), wobble: 2)))
        guard case let .polygon(found) = shape else { Issue.record("not a polygon: \(shape)"); return }
        #expect(found.count == 4)
        let expected = [Point2(101, 101), Point2(398.5, 101), Point2(398.5, 299), Point2(101, 299)]
        for (a, b) in zip(found, expected) {
            #expect(Self.near(a, b, within: 5), "\(a) vs \(b)")
        }
        #expect(abs(found[0].y - found[1].y) < 1e-3 && abs(found[1].x - found[2].x) < 1e-3, "axis-aligned")
    }

    @Test func nearSquareIsASquare() throws {
        let corners = [Point2(100, 100), Point2(300, 100), Point2(300, 290), Point2(100, 290)]
        let shape = try #require(ShapeRecognizer.recognize(Self.drawn(Self.polygon(corners), wobble: 1.5)))
        guard case let .polygon(found) = shape, found.count == 4 else { Issue.record("not a quad: \(shape)"); return }
        #expect(abs(norm(found[1] - found[0]) - norm(found[2] - found[1])) < 1e-2)
    }

    @Test func triangleKeepsItsCorners() throws {
        let corners = [Point2(200, 100), Point2(350, 350), Point2(60, 330)]
        let shape = try #require(ShapeRecognizer.recognize(Self.drawn(Self.polygon(corners, closing: 6), wobble: 2)))
        guard case let .polygon(found) = shape else { Issue.record("not a polygon: \(shape)"); return }
        #expect(found.count == 3)
        for (a, b) in zip(found, corners) {
            #expect(Self.near(a, b, within: 6), "\(a) vs \(b)")
        }
    }

    @Test func skewedQuadAndPentagonStayAsDrawn() throws {
        let rhombus = [Point2(100, 300), Point2(250, 100), Point2(500, 100), Point2(350, 300)]
        let quad = try #require(ShapeRecognizer.recognize(Self.drawn(Self.polygon(rhombus), wobble: 1.5)))
        guard case let .polygon(q) = quad else { Issue.record("not a polygon: \(quad)"); return }
        #expect(q.count == 4)
        #expect(zip(q, rhombus).allSatisfy { Self.near($0, $1, within: 6) }, "not squared off: \(q)")

        let pentagon = (0 ..< 5).map { i in
            let t = -Float.pi / 2 + 2 * .pi * Float(i) / 5
            return Point2(300 + 150 * cos(t), 300 + 150 * sin(t))
        }
        let five = try #require(ShapeRecognizer.recognize(Self.drawn(Self.polygon(pentagon), wobble: 1.5)))
        guard case let .polygon(p) = five else { Issue.record("not a polygon: \(five)"); return }
        #expect(p.count == 5)
    }

    @Test func openCurvesScribblesAndDotsDontSnap() {
        let arc = Self.drawn(Self.circle(center: Point2(300, 300), radius: Point2(100, 100), sweep: .pi), wobble: 1)
        #expect(ShapeRecognizer.recognize(arc) == nil, "half circle")
        let zigzag = Self.drawn([Point2(100, 100), Point2(150, 200), Point2(200, 100), Point2(250, 200), Point2(300, 100)], wobble: 1)
        #expect(ShapeRecognizer.recognize(zigzag) == nil, "zigzag")
        let spiral = (0 ... 300).map { i in
            let t = Float(i) / 300 * 4 * .pi
            return Point2(300 + (20 + 10 * t) * cos(t), 300 + (20 + 10 * t) * sin(t))
        }
        #expect(ShapeRecognizer.recognize(spiral) == nil, "spiral")
        #expect(ShapeRecognizer.recognize([Point2(100, 100), Point2(102, 101), Point2(103, 103)]) == nil, "dot")
        #expect(ShapeRecognizer.recognize([]) == nil)
    }

    /// Every wobble of each shape, small and large, reads as that shape.
    @Test(arguments: 1 ... 24)
    func shapesReadTheSameWhateverTheWobble(seed: UInt64) {
        for scale: Float in [0.15, 1] {
            let wobble = 3 * scale.squareRoot()
            let at = { (x: Float, y: Float) in Point2(x, y) * scale }
            let circle = Self.drawn(
                Self.circle(center: at(300, 300), radius: at(100, 104), from: Float(seed), sweep: 2 * .pi + 0.2), wobble: wobble, seed: seed
            )
            let rectangle = Self.drawn(
                Self.polygon([at(100, 100), at(420, 98), at(424, 260), at(98, 262)], closing: 10 * scale, rounding: 4 * scale.squareRoot()),
                wobble: wobble, seed: seed
            )
            let triangle = Self.drawn(
                Self.polygon([at(200, 100), at(330, 330), at(70, 330)], closing: 5 * scale, rounding: 4 * scale.squareRoot()),
                wobble: wobble,
                seed: seed
            )
            let line = Self.drawn([at(100, 100), at(500, 250)], wobble: wobble, seed: seed)
            if case let .ellipse(_, radii, _) = ShapeRecognizer.recognize(circle) {
                #expect(radii.x == radii.y, "seed \(seed) scale \(scale): circle")
            } else {
                Issue.record("seed \(seed) scale \(scale): circle read as \(String(describing: ShapeRecognizer.recognize(circle)))")
            }
            if case let .polygon(corners) = ShapeRecognizer.recognize(rectangle) {
                #expect(corners.count == 4 && abs(corners[0].y - corners[1].y) < 1e-3, "seed \(seed) scale \(scale): rectangle")
            } else {
                Issue.record("seed \(seed) scale \(scale): rectangle read as \(String(describing: ShapeRecognizer.recognize(rectangle)))")
            }
            if case let .polygon(corners) = ShapeRecognizer.recognize(triangle) {
                #expect(corners.count == 3, "seed \(seed) scale \(scale): triangle \(corners)")
            } else {
                Issue.record("seed \(seed) scale \(scale): triangle read as \(String(describing: ShapeRecognizer.recognize(triangle)))")
            }
            if case .line = ShapeRecognizer.recognize(line) {} else {
                Issue.record("seed \(seed) scale \(scale): line read as \(String(describing: ShapeRecognizer.recognize(line)))")
            }
        }
    }

    // MARK: SnapShape

    @Test func outlineTriplesCornersAndCloses() throws {
        let square = SnapShape.polygon([Point2(0, 0), Point2(10, 0), Point2(10, 10), Point2(0, 10)])
        let points = square.outline(spacing: 2)
        #expect(Array(points.prefix(3)) == [Point2(0, 0), Point2(0, 0), Point2(0, 0)])
        #expect(Array(points.suffix(3)) == [Point2(0, 0), Point2(0, 0), Point2(0, 0)])
        #expect(points.count { $0 == Point2(10, 10) } == 3)
        #expect(zip(points, points.dropFirst()).allSatisfy { norm($1 - $0) <= 2 + 1e-4 })

        let circle = SnapShape.ellipse(center: Point2(50, 50), radii: Point2(20, 20), rotation: 0).outline(spacing: 2)
        let (first, last) = try (#require(circle.first), #require(circle.last))
        #expect(norm(first - last) < 1e-3)
        #expect(circle.allSatisfy { abs(norm($0 - Point2(50, 50)) - 20) < 1e-3 })

        let line = SnapShape.line(Point2(0, 0), Point2(9, 0)).outline(spacing: 2)
        #expect(line.prefix(3).allSatisfy { $0 == Point2(0, 0) } && line.suffix(3).allSatisfy { $0 == Point2(9, 0) })
    }

    @Test func lineEndFollowsThePencilSnapping() {
        let line = SnapShape.line(Point2(0, 0), Point2(100, 0))
        #expect(line.adjusted(anchor: Point2(100, 0), to: Point2(200, 6)) == .line(Point2(0, 0), Point2(norm(Point2(200, 6)), 0)))
        guard case let .line(_, end) = line.adjusted(anchor: Point2(100, 0), to: Point2(100, 50)) else { return }
        #expect(abs(end.x - 100) < 1e-3 && abs(end.y - 50) < 1e-3, "26.6° is free")
    }

    @Test func closedShapeScalesAndRotatesAboutItsCenter() {
        let square = SnapShape.polygon([Point2(-10, -10), Point2(10, -10), Point2(10, 10), Point2(-10, 10)])
        // Corner dragged straight out: twice the size, no rotation.
        guard case let .polygon(bigger) = square.adjusted(anchor: Point2(10, 10), to: Point2(20, 20)) else { return }
        #expect(bigger == [Point2(-20, -20), Point2(20, -20), Point2(20, 20), Point2(-20, 20)])
        // A small wobble around the center doesn't tilt it.
        guard case let .polygon(steady) = square.adjusted(anchor: Point2(10, 10), to: Point2(10.5, 9.5)) else { return }
        #expect(abs(steady[0].y - steady[1].y) < 1e-3)
        // A deliberate turn does.
        guard case let .polygon(turned) = square.adjusted(anchor: Point2(10, 10), to: Point2(0, 14)) else { return }
        #expect(abs(turned[0].y - turned[1].y) > 5)

        let circle = SnapShape.ellipse(center: Point2(0, 0), radii: Point2(10, 10), rotation: 0)
        #expect(circle.adjusted(anchor: Point2(10, 0), to: Point2(30, 0)) == .ellipse(center: .zero, radii: Point2(30, 30), rotation: 0))
    }
}
