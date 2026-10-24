import CoreGraphics
import InkGeometry
import InkModel

/// Partial-mode eraser for one gesture on one page (ARCHITECTURE.md §6): strokes are cut where the
/// eraser disk covers their ink; the pieces outside it survive as new strokes.
///
/// Feed it the eraser samples as they arrive (one batch per touch event). Each call returns, for every
/// stroke the batch cut, its surviving pieces (`[]` if fully erased), for a `Page.replaceEdit` against
/// the page as the previous batches left it. The sweep, prefilter and per-gesture lifetime match
/// ``StrokeEraser``; the exact test is ``InkModel/Stroke/pieces(erasedBy:radius:minimumPieceLength:)``
/// (original samples kept, cut ends interpolated, rendering cut alike). Pieces are erasable by later
/// probes of the same gesture. Every pen is erasable, highlighter included.
public struct PartialEraser: Sendable {
    /// Pieces this short or shorter (pt) are dropped, so scrubbing leaves no dust.
    public static let minimumPieceLength: Float = 0.5

    /// Eraser radius (pt, page space).
    public var radius: CGFloat {
        path.radius
    }

    private var path: EraserPath
    /// Live strokes: the page's untouched ones plus surviving pieces.
    private var strokes: [StrokeID: Stroke]
    private var index: StrokeIndex
    private var gesture = Lineage()
    private var batch = Lineage()

    /// Starts a gesture over `page`'s strokes with an eraser of `diameter` points.
    public init(page: Page, diameter: Float) {
        path = EraserPath(diameter: diameter)
        strokes = Dictionary(page.strokes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        index = StrokeIndex(strokes: page.strokes)
    }

    /// Strokes and pieces currently on the page.
    public var liveCount: Int {
        strokes.count
    }

    /// The whole gesture so far: each stroke of the starting page that was cut, mapped to its surviving
    /// pieces in order (`[]` if gone). Against the starting page this is the gesture as one edit.
    public var gestureReplacements: [StrokeID: [Stroke]] {
        resolve(gesture)
    }

    /// Sweeps the eraser along `samples` (continuing from the previous batch) and returns this batch's
    /// replacements, keyed by strokes as they were before the batch.
    public mutating func erase(_ samples: [Sample]) -> [StrokeID: [Stroke]] {
        erase(samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
    }

    /// Same, for page-space points.
    public mutating func erase(_ points: [CGPoint]) -> [StrokeID: [Stroke]] {
        batch = Lineage()
        for center in path.advance(through: points) {
            probe(center)
        }
        return resolve(batch)
    }

    private mutating func probe(_ center: CGPoint) {
        let radius = path.radius
        for id in index.query(circleCenter: center, radius: radius) {
            guard let stroke = strokes[id],
                  let pieces = stroke.pieces(erasedBy: center, radius: radius, minimumPieceLength: Self.minimumPieceLength)
            else { continue }
            strokes[id] = nil
            index.remove(id)
            for piece in pieces {
                strokes[piece.id] = piece
                index.insert(piece)
            }
            let ids = pieces.map(\.id)
            gesture.replace(id, with: ids)
            batch.replace(id, with: ids)
        }
    }

    private func resolve(_ lineage: Lineage) -> [StrokeID: [Stroke]] {
        lineage.descendants.mapValues { $0.compactMap { strokes[$0] } }
    }
}

/// Which live pieces each original stroke has become, through repeated cuts.
private struct Lineage {
    /// Original stroke → its live pieces, in stroke order.
    private(set) var descendants: [StrokeID: [StrokeID]] = [:]
    /// Live piece → the original it came from.
    private var origin: [StrokeID: StrokeID] = [:]

    /// `id` (an original or a live piece) was cut into `pieces`.
    mutating func replace(_ id: StrokeID, with pieces: [StrokeID]) {
        let root = origin.removeValue(forKey: id) ?? id
        if var list = descendants[root], let i = list.firstIndex(of: id) {
            list.replaceSubrange(i ... i, with: pieces)
            descendants[root] = list
        } else {
            descendants[root] = pieces
        }
        for piece in pieces {
            origin[piece] = root
        }
    }
}
