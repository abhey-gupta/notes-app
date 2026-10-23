import CoreGraphics
import InkGeometry
import InkModel

/// Stroke-mode eraser for one gesture on one page (ARCHITECTURE.md §6): whole strokes touched by the
/// eraser disk go.
///
/// Feed it the eraser samples as they arrive (one batch per touch event); each call returns the strokes
/// newly hit, for a `PageEdit.remove`. The path between consecutive samples (across batches too) is
/// swept in steps of half the radius, so a fast flick doesn't skip a thin stroke. Candidates come from
/// a `StrokeIndex` (64 pt cells) on stroke bounds, then the exact outline-vs-disk test. Each stroke is
/// reported once per gesture.
///
/// Partial erase (#28) splits instead of removing; it will sit beside this type behind the same calls.
public struct StrokeEraser: Sendable {
    /// Eraser radius (pt, page space).
    public let radius: CGFloat
    private var strokes: [StrokeID: Stroke]
    private var index: StrokeIndex
    private var last: CGPoint?

    /// Starts a gesture over `page`'s strokes with an eraser of `diameter` points.
    public init(page: Page, diameter: Float) {
        radius = max(CGFloat(diameter) / 2, 0.5)
        strokes = Dictionary(page.strokes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        index = StrokeIndex(strokes: page.strokes)
    }

    /// Strokes the eraser has not hit yet.
    public var remainingCount: Int {
        strokes.count
    }

    /// Sweeps the eraser along `samples` (continuing from the previous batch) and returns the IDs of
    /// strokes newly touched, in no particular order.
    public mutating func erase(_ samples: [Sample]) -> [StrokeID] {
        erase(samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
    }

    /// Same, for page-space points.
    public mutating func erase(_ points: [CGPoint]) -> [StrokeID] {
        var hits: [StrokeID] = []
        let step = radius / 2
        for point in points where point.x.isFinite && point.y.isFinite {
            let from = last ?? point
            let distance = hypot(point.x - from.x, point.y - from.y)
            let count = min(max(Int((distance / step).rounded(.up)), 1), 4096)
            for i in 1 ... count {
                let t = CGFloat(i) / CGFloat(count)
                probe(CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t), into: &hits)
            }
            last = point
        }
        return hits
    }

    private mutating func probe(_ center: CGPoint, into hits: inout [StrokeID]) {
        for id in index.query(circleCenter: center, radius: radius) {
            guard let stroke = strokes[id], stroke.intersects(circleCenter: center, radius: radius) else { continue }
            hits.append(id)
            strokes[id] = nil
            _ = index.remove(id)
        }
    }
}
