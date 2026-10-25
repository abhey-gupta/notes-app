import Foundation
import InkModel

public extension StrokeRendering {
    /// How wide PencilKit draws each point (pt), perpendicular to the stroke: the ``InkModel/InkNib``
    /// of the point, cut across the stroke's heading there for chisel inks (fountain pen, marker),
    /// whose mark lies along the sample's azimuth. The heading at a sample runs from its nearest
    /// distinct predecessor to its nearest distinct successor; a sample with neither (a dot) gets the
    /// nib's widest extent. One value per `samples` element; `samples` must be parallel to ``points``.
    func drawnWidths(along samples: [Sample]) -> [Float] {
        let n = min(points.count, samples.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let nib = InkNib(ink: ink, point: points[i])
            if nib.isRound {
                out[i] = nib.along
                continue
            }
            guard let heading = Self.heading(samples, at: i) else {
                out[i] = nib.maximumWidth
                continue
            }
            let azimuth = samples[i].azimuth.isFinite ? samples[i].azimuth : 0
            let u = Point2(cos(azimuth), sin(azimuth))
            // Extent of the nib ellipse (semi-axes along and across `u`) along the stroke's normal.
            let a = nib.along / 2 * cross(heading, u)
            let b = nib.across / 2 * dot(heading, u)
            out[i] = 2 * (a * a + b * b).squareRoot()
        }
        return out
    }

    /// Unit heading at sample `i`, or `nil` if no distinct neighbor exists.
    private static func heading(_ samples: [Sample], at i: Int) -> Point2? {
        let p = Point2(samples[i].x, samples[i].y)
        func distinct(_ j: Int) -> Point2? {
            let q = Point2(samples[j].x, samples[j].y)
            guard q.x.isFinite, q.y.isFinite, norm(q - p) > 1e-3 else { return nil }
            return q
        }
        var before: Point2?
        var j = i - 1
        while j >= 0, before == nil {
            before = distinct(j)
            j -= 1
        }
        var after: Point2?
        var k = i + 1
        while k < samples.count, after == nil {
            after = distinct(k)
            k += 1
        }
        let d: Point2
        switch (before, after) {
        case let (b?, a?): d = a - b
        case let (b?, nil): d = p - b
        case let (nil, a?): d = a - p
        case (nil, nil): return nil
        }
        let length = norm(d)
        guard length > 1e-6 else { return nil }
        return d / length
    }
}
