import Foundation

/// Finds the perfect shape a freehand stroke was meant to be (#165): a line, an ellipse (a circle when
/// nearly round), or a closed polygon of 3–6 corners (a rectangle, a square when nearly so, when its
/// corners are nearly right angles). Open curves and scribbles give `nil`.
///
/// Scale-free: tolerances are fractions of the stroke's size, so it reads the same at any zoom.
public enum ShapeRecognizer {
    /// Strokes smaller than this (bounding-box diagonal, pt) never snap.
    public static let minimumSize: Float = 8
    /// Points the stroke is resampled to (evenly by arc length) before fitting.
    static let resampleCount = 128

    /// The shape `points` (a stroke's centerline, in drawing order) was meant to be, if any.
    public static func recognize(_ points: [Point2]) -> SnapShape? {
        let path = resample(points.filter { $0.x.isFinite && $0.y.isFinite }, count: resampleCount)
        guard path.count >= 8, let start = path.first, let end = path.last else { return nil }
        let size = diagonal(path)
        guard size >= minimumSize else { return nil }
        if isLine(path, start: start, end: end) {
            return .line(start, SnapShape.lineEnd(from: start, to: end))
        }
        guard let loop = closedLoop(path, size: size) else { return nil }
        let ellipse = fitEllipse(loop)
        let polygon = fitPolygon(loop, size: size)
        // A polygon fits any round loop roughly too (a circle is nearly a hexagon): it must fit clearly better.
        if let polygon, polygon.error < 0.6 * ellipse.error, polygon.error < 0.08 {
            return regularized(polygon.corners)
        }
        guard ellipse.error < 0.1 else { return nil }
        return regularized(ellipse.shape)
    }

    // MARK: Line

    /// Nearly straight: the path never strays far from its chord nor turns back along it.
    static func isLine(_ path: [Point2], start: Point2, end: Point2) -> Bool {
        let chord = norm(end - start)
        guard chord >= minimumSize else { return false }
        let direction = (end - start) / chord
        var (deviation, ahead, backtrack) = (Float(0), Float(0), Float(0))
        for p in path {
            deviation = max(deviation, abs(cross(direction, p - start)))
            let along = dot(direction, p - start)
            ahead = max(ahead, along)
            backtrack = max(backtrack, ahead - along)
        }
        return deviation / chord < 0.07 && backtrack / chord < 0.05
    }

    // MARK: Closure

    /// The path as a closed loop (without its closing point): trimmed where it comes back nearest its
    /// start after going farthest from it, so an overshoot past the start is dropped. `nil` when the
    /// end stays far from the start (an open curve).
    static func closedLoop(_ path: [Point2], size: Float) -> [Point2]? {
        guard let start = path.first else { return nil }
        let distances = path.map { norm($0 - start) }
        guard let far = distances.indices.max(by: { distances[$0] < distances[$1] }), far > 0,
              let close = distances.indices.dropFirst(far).min(by: { distances[$0] < distances[$1] }), distances[close] < 0.22 * size,
              close >= 6 else { return nil }
        return Array(path[..<close])
    }

    // MARK: Ellipse

    /// An ellipse along the loop's principal axes, spanning its extents, and the mean distance of the
    /// loop from it as a fraction of its mean radius.
    static func fitEllipse(_ loop: [Point2]) -> (shape: SnapShape, error: Float) {
        let mean = loop.reduce(Point2.zero, +) / Float(loop.count)
        var (sxx, syy, sxy) = (Float(0), Float(0), Float(0))
        for p in loop {
            let d = p - mean
            sxx += d.x * d.x
            syy += d.y * d.y
            sxy += d.x * d.y
        }
        let rotation = 0.5 * atan2(2 * sxy, sxx - syy)
        let axis = Point2(cos(rotation), sin(rotation))
        let normal = Point2(-axis.y, axis.x)
        let u = loop.map { dot($0 - mean, axis) }
        let v = loop.map { dot($0 - mean, normal) }
        guard let u0 = u.min(), let u1 = u.max(), let v0 = v.min(), let v1 = v.max() else {
            return (.ellipse(center: mean, radii: .zero, rotation: 0), .infinity)
        }
        let radii = Point2(max((u1 - u0) / 2, 1e-3), max((v1 - v0) / 2, 1e-3))
        let (du, dv) = ((u0 + u1) / 2, (v0 + v1) / 2)
        let center = mean + axis * du + normal * dv
        let error = zip(u, v).reduce(Float(0)) { sum, p in
            let rho = (pow((p.0 - du) / radii.x, 2) + pow((p.1 - dv) / radii.y, 2)).squareRoot()
            return sum + abs(rho - 1)
        } / Float(loop.count)
        return (.ellipse(center: center, radii: radii, rotation: rotation), error)
    }

    // MARK: Polygon

    /// Corners found by Douglas–Peucker on the loop, straight runs merged, each corner the meeting point
    /// of its two edges' fitted lines; with the loop's mean distance from the polygon as a fraction of
    /// its mean radius (as ``fitEllipse(_:)``'s). `nil` unless it has 3–6 corners.
    static func fitPolygon(_ loop: [Point2], size: Float) -> (corners: [Point2], error: Float)? {
        guard let far = loop.indices.max(by: { norm(loop[$0] - loop[0]) < norm(loop[$1] - loop[0]) }), far > 0 else { return nil }
        let tolerance = 0.045 * size
        let closed = loop + [loop[0]]
        var indices = simplify(closed, 0, far, tolerance) + simplify(closed, far, loop.count, tolerance)
        indices = indices.filter { $0 < loop.count }
        indices = mergingStraightRuns(indices, in: loop, size: size)
        guard (3 ... 6).contains(indices.count) else { return nil }
        let corners = refinedCorners(indices, in: loop, size: size)
        let mean = loop.reduce(Point2.zero, +) / Float(loop.count)
        let radius = loop.reduce(Float(0)) { $0 + norm($1 - mean) } / Float(loop.count)
        let error = loop.reduce(Float(0)) { $0 + distance($1, toPolygon: corners) } / Float(loop.count)
        return (corners, error / max(radius, 1e-3))
    }

    /// Douglas–Peucker: indices of `points[from..<to]` kept at `tolerance` (`from` included, `to` not).
    private static func simplify(_ points: [Point2], _ from: Int, _ to: Int, _ tolerance: Float) -> [Int] {
        guard to - from > 1 else { return [from] }
        let (a, b) = (points[from], points[to])
        var (worst, worstDistance) = (from, Float(0))
        for i in from + 1 ..< to {
            let d = distance(points[i], toSegment: a, b)
            if d > worstDistance {
                (worst, worstDistance) = (i, d)
            }
        }
        guard worstDistance > tolerance else { return [from] }
        return simplify(points, from, worst, tolerance) + simplify(points, worst, to, tolerance)
    }

    /// Drops corners where the loop barely turns (< 30°), the flattest first, and one of any two corners
    /// closer than 8% of the size (a rounded corner read twice), until neither is left.
    private static func mergingStraightRuns(_ indices: [Int], in loop: [Point2], size: Float) -> [Int] {
        var kept = indices
        while kept.count > 3 {
            let n = kept.count
            let turns = kept.indices.map { i in turn(loop[kept[(i + n - 1) % n]], loop[kept[i]], loop[kept[(i + 1) % n]]) }
            if let close = kept.indices.first(where: { norm(loop[kept[($0 + 1) % n]] - loop[kept[$0]]) < 0.08 * size }) {
                kept.remove(at: turns[close] < turns[(close + 1) % n] ? close : (close + 1) % n)
                continue
            }
            guard let flattest = turns.indices.min(by: { turns[$0] < turns[$1] }), turns[flattest] < .pi / 6 else { break }
            kept.remove(at: flattest)
        }
        return kept
    }

    /// Each corner moved to where its two edges' fitted lines meet (the drawn corner itself is usually
    /// rounded), unless they meet far from it.
    private static func refinedCorners(_ indices: [Int], in loop: [Point2], size: Float) -> [Point2] {
        let lines = indices.indices.map { i in
            edgeLine(loop, from: indices[i], to: indices[(i + 1) % indices.count])
        }
        return indices.indices.map { i in
            let drawn = loop[indices[i]]
            let previous = lines[(i + lines.count - 1) % lines.count]
            guard let meet = intersection(previous, lines[i]), norm(meet - drawn) < 0.15 * size else { return drawn }
            return meet
        }
    }

    /// The least-squares line through the middle 70% of the loop from `from` to `to` (wrapping).
    private static func edgeLine(_ loop: [Point2], from: Int, to: Int) -> (point: Point2, direction: Point2) {
        let count = (to - from + loop.count) % loop.count
        let skip = Int(Float(count) * 0.15)
        let points = (skip ... max(count - skip, skip)).map { loop[(from + $0) % loop.count] }
        let mean = points.reduce(Point2.zero, +) / Float(points.count)
        var (sxx, syy, sxy) = (Float(0), Float(0), Float(0))
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            syy += d.y * d.y
            sxy += d.x * d.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (mean, Point2(cos(angle), sin(angle)))
    }

    // MARK: Regularizing

    /// Near-circles become circles; an ellipse's axis snaps to a whole 45° when close.
    private static func regularized(_ ellipse: SnapShape) -> SnapShape {
        guard case let .ellipse(center, radii, rotation) = ellipse else { return ellipse }
        if min(radii.x, radii.y) / max(radii.x, radii.y) > 0.85 {
            let r = (radii.x + radii.y) / 2
            return .ellipse(center: center, radii: Point2(r, r), rotation: 0)
        }
        return .ellipse(center: center, radii: radii, rotation: SnapShape.snapped(rotation))
    }

    /// Four near-right-angled corners become a rectangle (a square when its sides are nearly equal),
    /// its sides snapped to whole 45°s when close; other polygons stay as drawn.
    private static func regularized(_ corners: [Point2]) -> SnapShape {
        guard corners.count == 4 else { return .polygon(corners) }
        let rightAngled = corners.indices.allSatisfy { i in
            abs(turn(corners[(i + 3) % 4], corners[i], corners[(i + 1) % 4]) - .pi / 2) < 15 * .pi / 180
        }
        guard rightAngled else { return .polygon(corners) }
        // Mean edge direction modulo 90° (angles × 4 averaged on the circle).
        let sum = corners.indices.reduce(Point2.zero) { sum, i in
            let d = corners[(i + 1) % 4] - corners[i]
            let angle = 4 * atan2(d.y, d.x)
            return sum + Point2(cos(angle), sin(angle)) * norm(d)
        }
        let angle = SnapShape.snapped(atan2(sum.y, sum.x) / 4)
        let axis = Point2(cos(angle), sin(angle))
        let normal = Point2(-axis.y, axis.x)
        let u = corners.map { dot($0, axis) }
        let v = corners.map { dot($0, normal) }
        guard let u0 = u.min(), let u1 = u.max(), let v0 = v.min(), let v1 = v.max() else { return .polygon(corners) }
        var (w, h) = ((u1 - u0) / 2, (v1 - v0) / 2)
        if abs(w - h) / max(w, h) < 0.12 {
            (w, h) = ((w + h) / 2, (w + h) / 2)
        }
        let center = axis * (u0 + u1) / 2 + normal * (v0 + v1) / 2
        // Same corner order and starting corner as drawn.
        return .polygon(corners.map { p in
            let du: Float = dot(p - center, axis) < 0 ? -w : w
            let dv: Float = dot(p - center, normal) < 0 ? -h : h
            return center + axis * du + normal * dv
        })
    }

    // MARK: Helpers

    /// `points` resampled to `count` points evenly spaced along their path.
    static func resample(_ points: [Point2], count: Int) -> [Point2] {
        guard points.count > 1, count > 1 else { return points }
        let total = pathLength(points)
        guard total > 0 else { return [points[0]] }
        let step = total / Float(count - 1)
        var result = [points[0]]
        var (i, travelled, carried) = (1, Float(0), points[0])
        while result.count < count - 1, i < points.count {
            let segment = norm(points[i] - carried)
            if travelled + segment >= step, segment > 0 {
                carried += (points[i] - carried) * ((step - travelled) / segment)
                result.append(carried)
                travelled = 0
            } else {
                travelled += segment
                carried = points[i]
                i += 1
            }
        }
        return result + [points[points.count - 1]]
    }

    static func pathLength(_ points: [Point2]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { $0 + norm($1.1 - $1.0) }
    }

    private static func diagonal(_ points: [Point2]) -> Float {
        var box = BoundsBuilder()
        for p in points {
            box.add(p)
        }
        return norm(box.upper - box.lower)
    }

    /// How far the path turns at `b` (0 straight on, π back on itself).
    private static func turn(_ a: Point2, _ b: Point2, _ c: Point2) -> Float {
        let (u, v) = (b - a, c - b)
        guard norm(u) > 0, norm(v) > 0 else { return 0 }
        return abs(atan2(cross(u, v), dot(u, v)))
    }

    private static func distance(_ p: Point2, toSegment a: Point2, _ b: Point2) -> Float {
        let ab = b - a
        let length2 = dot(ab, ab)
        guard length2 > 0 else { return norm(p - a) }
        let t = min(max(dot(p - a, ab) / length2, 0), 1)
        return norm(p - (a + ab * t))
    }

    private static func distance(_ p: Point2, toPolygon corners: [Point2]) -> Float {
        corners.indices.reduce(Float.infinity) { min($0, distance(p, toSegment: corners[$1], corners[($1 + 1) % corners.count])) }
    }

    private static func intersection(_ l1: (point: Point2, direction: Point2), _ l2: (point: Point2, direction: Point2)) -> Point2? {
        let denominator = cross(l1.direction, l2.direction)
        guard abs(denominator) > 0.1 else { return nil } // nearly parallel (< ~6°)
        let t = cross(l2.point - l1.point, l2.direction) / denominator
        return l1.point + l1.direction * t
    }
}
