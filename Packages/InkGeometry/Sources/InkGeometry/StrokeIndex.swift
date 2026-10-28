import CoreGraphics
import InkModel

/// Per-page uniform-grid spatial index over stroke bounds (ARCHITECTURE.md §6).
///
/// Each stroke is registered in every cell its bounds overlap. Queries return exactly the strokes
/// whose bounds overlap the query rect (closed intervals: touching counts), deduplicated; follow up
/// with an exact test such as ``InkModel/Stroke/intersects(circleCenter:radius:)``.
public struct StrokeIndex: Sendable {
    /// Default cell edge in points.
    public static let defaultCellSize: CGFloat = 64

    private struct Cell: Hashable {
        var x: Int
        var y: Int
    }

    /// Cell edge in points.
    public let cellSize: CGFloat
    private var cells: [Cell: [StrokeID]] = [:]
    private var entries: [StrokeID: CGRect] = [:]
    /// Strokes spanning more than `maxCellsPerStroke` cells: kept out of the grid, checked on every query.
    private var oversized: Set<StrokeID> = []
    private static let maxCellsPerStroke = 4096

    /// Creates an empty index.
    public init(cellSize: CGFloat = StrokeIndex.defaultCellSize) {
        self.cellSize = cellSize > 0 && cellSize.isFinite ? cellSize : Self.defaultCellSize
    }

    /// Creates an index of `strokes`.
    public init(strokes: some Sequence<Stroke>, cellSize: CGFloat = StrokeIndex.defaultCellSize) {
        self.init(cellSize: cellSize)
        for stroke in strokes {
            insert(stroke)
        }
    }

    /// Number of indexed strokes.
    public var count: Int {
        entries.count
    }

    /// Whether `id` is indexed.
    public func contains(_ id: StrokeID) -> Bool {
        entries[id] != nil
    }

    /// Bounds registered for `id`.
    public func bounds(of id: StrokeID) -> CGRect? {
        entries[id]
    }

    /// Indexes `stroke` by its bounds (replacing any previous entry with the same ID).
    public mutating func insert(_ stroke: Stroke) {
        insert(stroke.id, bounds: stroke.bounds)
    }

    /// Indexes `id` with `bounds` (replacing any previous entry). Null/empty-sample bounds are ignored.
    public mutating func insert(_ id: StrokeID, bounds: CGRect) {
        remove(id)
        guard let range = cellRange(bounds) else { return }
        entries[id] = bounds
        guard Self.cellCount(range) <= Double(Self.maxCellsPerStroke) else {
            oversized.insert(id)
            return
        }
        for y in range.y {
            for x in range.x {
                cells[Cell(x: x, y: y), default: []].append(id)
            }
        }
    }

    /// Removes `id`. Returns whether it was indexed.
    @discardableResult
    public mutating func remove(_ id: StrokeID) -> Bool {
        guard let bounds = entries.removeValue(forKey: id), let range = cellRange(bounds) else { return false }
        if oversized.remove(id) != nil {
            return true
        }
        for y in range.y {
            for x in range.x {
                let cell = Cell(x: x, y: y)
                cells[cell]?.removeAll { $0 == id }
                if cells[cell]?.isEmpty == true {
                    cells[cell] = nil
                }
            }
        }
        return true
    }

    /// Keeps the index in sync with an applied ``InkModel/PageEdit``. Transforms need the
    /// post-edit strokes, so pass the edited page.
    public mutating func apply(_ edit: PageEdit, editedPage page: Page) {
        switch edit {
        case let .add(placed):
            for p in placed {
                insert(p.stroke)
            }
        case let .remove(placed):
            for p in placed {
                remove(p.stroke.id)
            }
        case let .replace(old, new):
            for p in old {
                remove(p.stroke.id)
            }
            for p in new {
                insert(p.stroke)
            }
        case let .transform(ids, _, _):
            let wanted = Set(ids)
            for stroke in page.strokes where wanted.contains(stroke.id) {
                insert(stroke)
            }
        case .recolor, .addImages, .removeImages, .transformImages:
            break
        }
    }

    /// IDs whose bounds overlap `rect`, in unspecified order.
    public func query(_ rect: CGRect) -> [StrokeID] {
        guard let range = cellRange(rect) else { return [] }
        // A huge query is cheaper as a scan of the entries.
        if Self.cellCount(range) > Double(entries.count) {
            return entries.compactMap { overlaps($0.value, rect) ? $0.key : nil }
        }
        var seen = Set<StrokeID>()
        var out: [StrokeID] = []
        for id in oversized where overlaps(entries[id] ?? .null, rect) {
            seen.insert(id)
            out.append(id)
        }
        for y in range.y {
            for x in range.x {
                guard let ids = cells[Cell(x: x, y: y)] else { continue }
                for id in ids where seen.insert(id).inserted {
                    if let b = entries[id], overlaps(b, rect) {
                        out.append(id)
                    }
                }
            }
        }
        return out
    }

    /// IDs whose bounds overlap the square around a disk (eraser prefilter).
    public func query(circleCenter center: CGPoint, radius: CGFloat) -> [StrokeID] {
        query(CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    private static func cellCount(_ range: (x: ClosedRange<Int>, y: ClosedRange<Int>)) -> Double {
        Double(range.x.count) * Double(range.y.count)
    }

    private func cellRange(_ rect: CGRect) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let limit = CGFloat(Int32.max)
        func cell(_ v: CGFloat) -> Int {
            Int(min(max((v / cellSize).rounded(.down), -limit), limit))
        }
        return (cell(rect.minX) ... cell(rect.maxX), cell(rect.minY) ... cell(rect.maxY))
    }
}
