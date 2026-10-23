import CoreGraphics
import InkModel

/// Partial-eraser geometry: cuts a raw-sample polyline where an eraser disk covers it.
public enum EraserSplit {
    /// Splits `samples` by a disk, keeping the parts outside it.
    ///
    /// Segments are clipped exactly at the circle; boundary samples are interpolated (position,
    /// force, altitude, azimuth along the shorter arc, time). Each piece's `t` is rebased to start at 0.
    /// Points exactly on the circle count as outside.
    ///
    /// - Parameters:
    ///   - center: Disk center (page space).
    ///   - radius: Disk radius. To erase what the user *sees*, inflate the eraser radius by the
    ///     stroke's half-width (``InkModel/Stroke/pieces(erasedBy:radius:)`` does).
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
        guard let first = samples.first, radius > 0, radius.isFinite else { return nil }
        let r2 = radius * radius
        if samples.count == 1 {
            let d = Point2(first.x, first.y) - center
            return dot(d, d) < r2 ? [] : nil
        }

        var pieces = PieceCollector(minimumLength: minimumPieceLength)
        var hit = false
        let d0 = Point2(first.x, first.y) - center
        if dot(d0, d0) >= r2 {
            pieces.current = [first]
        }

        for (a, b) in zip(samples, samples.dropFirst()) {
            guard let (u0, u1) = coveredInterval(a, b, center: center, r2: r2) else {
                // Untouched segment. (`current == nil` here only through rounding at a tangency.)
                pieces.current = (pieces.current ?? [a]) + [b]
                continue
            }
            hit = true
            if u0 > 0 {
                pieces.current = (pieces.current ?? [a]) + [interpolate(a, b, u0)]
            }
            pieces.close()
            if u1 < 1 {
                pieces.current = [interpolate(a, b, u1), b]
            }
        }
        pieces.close()
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
        let minimumLength: Float
        var pieces: [[Sample]] = []
        var current: [Sample]?

        mutating func close() {
            guard let piece = current else { return }
            current = nil
            var length: Float = 0
            for (a, b) in zip(piece, piece.dropFirst()) {
                length += norm(Point2(b.x - a.x, b.y - a.y))
            }
            guard piece.count >= 2, length > minimumLength else { return }
            let t0 = piece[0].t
            pieces.append(piece.map { s in
                var s = s
                s.t -= t0
                return s
            })
        }
    }

    /// Linear interpolation of every sample field; azimuth takes the shorter arc.
    static func interpolate(_ a: Sample, _ b: Sample, _ u: Float) -> Sample {
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
}

public extension Stroke {
    /// Partial erase: the pieces of this stroke left after erasing a disk, as new strokes (fresh IDs,
    /// same pen, color, width). The disk is inflated by half the base width, so ink visibly under the
    /// eraser goes and surviving round caps end at the eraser's edge.
    /// - Returns: `nil` if untouched; otherwise the pieces (`[]` if fully erased). Feed into
    ///   `Page.replaceEdit`.
    func pieces(erasedBy center: CGPoint, radius: CGFloat) -> [Stroke]? {
        EraserSplit.split(samples, center: Point2(center), radius: Float(radius) + width / 2)?
            .map { Stroke(tool: tool, color: color, width: width, samples: $0) }
    }
}
