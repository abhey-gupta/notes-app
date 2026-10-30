import CoreGraphics
import InkModel

public extension Stroke {
    /// A stroke drawn from `page` that may run onto other pages without the Pencil lifting (#163), as the
    /// piece each page keeps: cut exactly where it enters another page, each piece in its own page's space.
    ///
    /// The stroke belongs to `page` until it enters another page's frame, then to that page, and so on;
    /// stretches off every page (the gutter beside narrow pages) stay with the page drawn on last. Cut ends
    /// are interpolated (samples and rendering alike, as the partial eraser cuts), so neighbouring pieces meet
    /// at the page edge; each piece's `t` starts at 0. The first piece keeps the
    /// stroke's ID, the others get fresh ones. Pieces left with fewer than two samples are dropped.
    ///
    /// - Parameter pages: Frames in one shared space (content space), `page` among them.
    /// - Returns: `[(page, self)]` when the stroke never enters another page.
    func pieces(from page: PageID, across pages: [(id: PageID, frame: CGRect)]) -> [(page: PageID, stroke: Stroke)] {
        guard samples.count > 1, let start = pages.first(where: { $0.id == page }) else { return [(page, self)] }
        let origin = start.frame.origin
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(samples[i].x) + origin.x, y: CGFloat(samples[i].y) + origin.y)
        }
        var owners = [start]
        var bounds = [EraserSplit.Position(index: 0, fraction: 0)]
        for i in 1 ..< samples.count {
            let p = point(i)
            guard let owner = owners.last, !owner.frame.contains(p),
                  let next = pages.first(where: { $0.id != owner.id && $0.frame.contains(p) })
            else { continue }
            let u = Self.entry(from: point(i - 1), to: p, into: next.frame)
            bounds.append(u < 1 ? EraserSplit.Position(index: i - 1, fraction: Float(u)) : EraserSplit.Position(index: i, fraction: 0))
            owners.append(next)
        }
        guard owners.count > 1 else { return [(page, self)] }
        bounds.append(EraserSplit.Position(index: samples.count - 1, fraction: 0))

        var pieces: [(page: PageID, stroke: Stroke)] = []
        for (k, owner) in owners.enumerated() {
            let span = EraserSplit.Span(start: bounds[k], end: bounds[k + 1])
            var piece = span.values(of: samples, interpolate: EraserSplit.interpolate)
            guard piece.count > 1 else { continue }
            let (dx, dy, t0) = (Float(origin.x - owner.frame.minX), Float(origin.y - owner.frame.minY), piece[0].t)
            for j in piece.indices {
                piece[j].x += dx
                piece[j].y += dy
                piece[j].t -= t0
            }
            var pieceRendering = rendering
            if let rendering {
                pieceRendering?.points = span.values(of: rendering.points, interpolate: EraserSplit.interpolate)
            }
            pieces.append((owner.id, Stroke(
                id: k == 0 ? id : StrokeID(), tool: tool, color: color, width: width, samples: piece, rendering: pieceRendering
            )))
        }
        return pieces
    }

    /// Where segment `a → b` (`b` inside `rect`, `a` outside) enters `rect`, as a fraction of the segment.
    private static func entry(from a: CGPoint, to b: CGPoint, into rect: CGRect) -> CGFloat {
        var u: CGFloat = 0
        for (p, d, low, high) in [(a.x, b.x - a.x, rect.minX, rect.maxX), (a.y, b.y - a.y, rect.minY, rect.maxY)] {
            if d > 0 {
                u = max(u, (low - p) / d)
            } else if d < 0 {
                u = max(u, (high - p) / d)
            }
        }
        return min(max(u, 0), 1)
    }
}
