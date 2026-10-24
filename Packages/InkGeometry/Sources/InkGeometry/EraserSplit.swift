import CoreGraphics
import InkModel

/// Partial-eraser geometry: cuts a raw-sample polyline where an eraser disk covers it.
public enum EraserSplit {
    /// A point on a polyline: sample `index`, moved `fraction` (`0 ..< 1`) of the way to the next sample.
    public struct Position: Hashable, Sendable {
        public var index: Int
        public var fraction: Float

        public init(index: Int, fraction: Float) {
            self.index = index
            self.fraction = fraction
        }
    }

    /// A surviving piece of a polyline, from `start` to `end` (inclusive).
    public struct Span: Hashable, Sendable {
        public var start: Position
        public var end: Position

        public init(start: Position, end: Position) {
            self.start = start
            self.end = end
        }

        /// The piece's values: the (interpolated) start, every original value strictly between, the
        /// (interpolated) end. Works for anything parallel to the samples (e.g. rendered point sizes).
        public func values<T>(of values: [T], interpolate: (T, T, Float) -> T) -> [T] {
            func at(_ p: Position) -> T {
                p.fraction > 0 ? interpolate(values[p.index], values[p.index + 1], p.fraction) : values[p.index]
            }
            var out = [at(start)]
            if start.index < end.index {
                out += values[(start.index + 1) ... end.index]
            }
            if end.fraction > 0 {
                out.append(at(end))
            }
            return out
        }
    }

    /// Splits `samples` by a disk, keeping the parts outside it.
    ///
    /// Segments are clipped exactly at the circle; boundary samples are interpolated (position,
    /// force, altitude, azimuth along the shorter arc, time). Each piece's `t` is rebased to start at 0.
    /// Points exactly on the circle count as outside.
    ///
    /// - Parameters:
    ///   - center: Disk center (page space).
    ///   - radius: Disk radius. To erase what the user *sees*, inflate the eraser radius by the
    ///     stroke's half-width (``InkModel/Stroke/pieces(erasedBy:radius:minimumPieceLength:)`` does).
    ///   - minimumPieceLength: Pieces this short or shorter (pt) are dropped.
    /// - Returns: `nil` if the disk does not touch the polyline (nothing to do); otherwise the
    ///   surviving pieces in order, each with ≥ 2 samples (`[]` if fully erased). A single-sample
    ///   polyline is either untouched (`nil`) or fully erased (`[]`).
    public static func split(
        _ samples: [Sample],
        center: Point2,
        radius: Float,
        minimumPieceLength: Float = 0
    ) -> [[Sample]]? {
        cut(samples, center: center, radius: radius, inflation: nil, minimumPieceLength: minimumPieceLength)?.map(\.samples)
    }

    /// ``split(_:center:radius:minimumPieceLength:)``, also returning where each piece lies on the
    /// input, so data parallel to the samples can be cut alike (``Span/values(of:interpolate:)``).
    ///
    /// - Parameter inflation: Optional per-sample extra radius (e.g. the ink's half-width at each
    ///   sample). Each segment uses the larger of its two ends'.
    public static func cut(
        _ samples: [Sample],
        center: Point2,
        radius: Float,
        inflation: [Float]? = nil,
        minimumPieceLength: Float = 0
    ) -> [(span: Span, samples: [Sample])]? {
        cut(samples, center: center, radius: radius, minimumPieceLength: minimumPieceLength) { i in
            guard let inflation, i < inflation.count, inflation[i].isFinite else { return 0 }
            return max(inflation[i], 0)
        }
    }

    /// `inflation(i)`: extra radius at sample `i` (finite, ≥ 0).
    static func cut(
        _ samples: [Sample],
        center: Point2,
        radius: Float,
        minimumPieceLength: Float,
        inflation: (Int) -> Float
    ) -> [(span: Span, samples: [Sample])]? {
        guard !samples.isEmpty, radius > 0, radius.isFinite else { return nil }
        func reach(_ i: Int) -> Float {
            radius + inflation(i)
        }
        func outside(_ i: Int) -> Bool {
            let d = Point2(samples[i].x, samples[i].y) - center
            let r = reach(i)
            return dot(d, d) >= r * r
        }
        if samples.count == 1 {
            return outside(0) ? nil : []
        }

        var pieces = PieceCollector(samples: samples, minimumLength: minimumPieceLength)
        var hit = false
        var start: Position? = outside(0) ? Position(index: 0, fraction: 0) : nil
        for i in 0 ..< samples.count - 1 {
            let r = max(reach(i), reach(i + 1))
            guard let (u0, u1) = coveredInterval(samples[i], samples[i + 1], center: center, r2: r * r) else {
                // Untouched segment. (`start == nil` here only through rounding at a tangency.)
                if start == nil {
                    start = Position(index: i, fraction: 0)
                }
                continue
            }
            hit = true
            if u0 > 0 || start != nil {
                pieces.close(start ?? Position(index: i, fraction: 0), Position(index: i, fraction: u0))
            }
            start = u1 < 1 ? Position(index: i, fraction: u1) : nil
        }
        if let start {
            pieces.close(start, Position(index: samples.count - 1, fraction: 0))
        }
        return hit ? pieces.pieces : nil
    }

    /// Parameter interval `[u0, u1] ⊂ [0, 1]` of segment `ab` strictly inside the disk, if non-empty:
    /// solves `|a + u·(b − a) − c|² = r²`.
    private static func coveredInterval(_ a: Sample, _ b: Sample, center: Point2, r2: Float) -> (Float, Float)? {
        let pa = Point2(a.x, a.y)
        let ab = Point2(b.x, b.y) - pa
        let f = pa - center
        let qa = dot(ab, ab)
        let qb = dot(f, ab)
        let qc = dot(f, f) - r2
        if qa == 0 {
            return qc < 0 ? (0, 1) : nil
        } // zero-length segment
        let disc = qb * qb - qa * qc
        guard disc > 0 else { return nil }
        let s = disc.squareRoot()
        let u0 = max((-qb - s) / qa, 0)
        let u1 = min((-qb + s) / qa, 1)
        return u0 < u1 ? (u0, u1) : nil
    }

    /// Accumulates surviving pieces, dropping short ones and rebasing time.
    private struct PieceCollector {
        let samples: [Sample]
        let minimumLength: Float
        var pieces: [(span: Span, samples: [Sample])] = []

        mutating func close(_ start: Position, _ end: Position) {
            let span = Span(start: start, end: end)
            let piece = span.values(of: samples, interpolate: EraserSplit.interpolate)
            var length: Float = 0
            for (a, b) in zip(piece, piece.dropFirst()) {
                length += norm(Point2(b.x - a.x, b.y - a.y))
            }
            guard piece.count >= 2, length > minimumLength else { return }
            let t0 = piece[0].t
            pieces.append((span, piece.map { s in
                var s = s
                s.t -= t0
                return s
            }))
        }
    }

    /// Linear interpolation of every sample field; azimuth takes the shorter arc.
    public static func interpolate(_ a: Sample, _ b: Sample, _ u: Float) -> Sample {
        var dAzimuth = (b.azimuth - a.azimuth).truncatingRemainder(dividingBy: 2 * .pi)
        if dAzimuth > .pi {
            dAzimuth -= 2 * .pi
        } else if dAzimuth < -.pi {
            dAzimuth += 2 * .pi
        }
        return Sample(
            x: a.x + (b.x - a.x) * u,
            y: a.y + (b.y - a.y) * u,
            force: a.force + (b.force - a.force) * u,
            altitude: a.altitude + (b.altitude - a.altitude) * u,
            azimuth: a.azimuth + dAzimuth * u,
            t: a.t + (b.t - a.t) * u
        )
    }

    /// Linear interpolation of every rendered-point field.
    public static func interpolate(_ a: PointRendering, _ b: PointRendering, _ u: Float) -> PointRendering {
        func mix(_ x: Float, _ y: Float) -> Float {
            x + (y - x) * u
        }
        return PointRendering(
            width: mix(a.width, b.width),
            height: mix(a.height, b.height),
            opacity: mix(a.opacity, b.opacity),
            secondaryScale: a.secondaryScale + (b.secondaryScale - a.secondaryScale) * Double(u),
            threshold: mix(a.threshold, b.threshold),
            lateralJitter: mix(a.lateralJitter, b.lateralJitter)
        )
    }
}

public extension Stroke {
    /// Partial erase: the pieces of this stroke left after erasing a disk, as new strokes (fresh IDs,
    /// same pen, color, width). Samples outside the disk are kept as they are; cut ends are
    /// interpolated. The disk is inflated by the ink's half-width (per sample from the stored point
    /// sizes when the stroke has a ``InkModel/Stroke/rendering``, else half the base width), so ink
    /// visibly under the eraser goes and surviving round caps end at the eraser's edge. A rendering is
    /// cut alongside the samples (same ink, seed, render group).
    /// - Parameter minimumPieceLength: Pieces this short or shorter (pt) are dropped (eraser dust).
    /// - Returns: `nil` if untouched; otherwise the pieces (`[]` if fully erased). Feed into
    ///   `Page.replaceEdit`.
    func pieces(erasedBy center: CGPoint, radius: CGFloat, minimumPieceLength: Float = 0) -> [Stroke]? {
        let halfWidth = width.isFinite ? max(width, 0) / 2 : 0
        let points = rendering?.points
        let cuts = EraserSplit.cut(samples, center: Point2(center), radius: Float(radius), minimumPieceLength: minimumPieceLength) { i in
            guard let points else { return halfWidth }
            let size = max(points[i].width, points[i].height)
            return size.isFinite ? max(size, 0) / 2 : halfWidth
        }
        return cuts?.map { cut in
            var pieceRendering = rendering
            if let rendering {
                pieceRendering?.points = cut.span.values(of: rendering.points, interpolate: EraserSplit.interpolate)
            }
            return Stroke(tool: tool, color: color, width: width, samples: cut.samples, rendering: pieceRendering)
        }
    }
}
