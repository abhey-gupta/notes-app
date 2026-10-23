import CoreGraphics

/// One page: template plus strokes in z-order (index 0 is bottom). Strokes change only via ``apply(_:)``.
public struct Page: Hashable, Sendable, Codable, Identifiable {
    /// Stable identity (UUIDv7).
    public let id: PageID
    /// Background template.
    public var template: PageTemplate
    /// Strokes, bottom to top.
    public private(set) var strokes: [Stroke]
    /// Page revision, bumped by every successful ``apply(_:)``. For checkpoints and future sync.
    public private(set) var rev: UInt64

    /// Creates a page (e.g. when decoding a stroke file).
    public init(id: PageID = PageID(), template: PageTemplate = .blank, strokes: [Stroke] = [], rev: UInt64 = 0) {
        self.id = id
        self.template = template
        self.strokes = strokes
        self.rev = rev
    }

    /// Z-index of the stroke with `id`, if present. O(n).
    public func index(of id: StrokeID) -> Int? {
        strokes.firstIndex { $0.id == id }
    }

    // MARK: Applying

    /// Applies `edit` atomically (all or nothing) and bumps ``rev``.
    /// - Returns: Union of the bounds of every stroke touched, before and after: the rect to invalidate.
    @discardableResult
    public mutating func apply(_ edit: PageEdit) throws(PageEditError) -> CGRect {
        var working = strokes
        var dirty = CGRect.null
        switch edit {
        case let .add(placed):
            try Self.insert(placed, into: &working, dirty: &dirty)
        case let .remove(placed):
            try Self.remove(placed, from: &working, dirty: &dirty)
        case let .replace(old, new):
            try Self.remove(old, from: &working, dirty: &dirty)
            try Self.insert(new, into: &working, dirty: &dirty)
        case let .transform(ids, forward, _):
            for i in try Self.indices(of: ids, in: working) {
                dirty = dirty.union(working[i].bounds)
                working[i] = working[i].transformed(by: forward)
                dirty = dirty.union(working[i].bounds)
            }
        case let .recolor(changes):
            for (i, change) in try zip(Self.indices(of: changes.map(\.id), in: working), changes) {
                dirty = dirty.union(working[i].bounds)
                working[i].color = change.to
            }
        }
        strokes = working
        rev &+= 1
        return dirty
    }

    /// Non-mutating ``apply(_:)``.
    public func applying(_ edit: PageEdit) throws(PageEditError) -> Page {
        var copy = self
        try copy.apply(edit)
        return copy
    }

    // MARK: Edit factories

    /// Edit that appends `strokes` on top, in order.
    public func addEdit(_ strokes: [Stroke]) -> PageEdit {
        .add(strokes.enumerated().map { PlacedStroke(index: self.strokes.count + $0.offset, stroke: $0.element) })
    }

    /// Edit that removes the strokes with `ids` (stroke eraser, lasso delete).
    public func removeEdit(_ ids: some Sequence<StrokeID>) throws(PageEditError) -> PageEdit {
        try .remove(Self.indices(of: Array(ids), in: strokes).sorted().map { PlacedStroke(index: $0, stroke: strokes[$0]) })
    }

    /// Edit that replaces each key stroke with its pieces at the same z-position (partial eraser).
    /// An empty piece list removes the stroke. Pieces need fresh IDs.
    public func replaceEdit(_ replacements: [StrokeID: [Stroke]]) throws(PageEditError) -> PageEdit {
        for id in replacements.keys where index(of: id) == nil {
            throw .unknownStroke(id)
        }
        var old: [PlacedStroke] = []
        var new: [PlacedStroke] = []
        var resultCount = 0
        for (i, stroke) in strokes.enumerated() {
            if let pieces = replacements[stroke.id] {
                old.append(PlacedStroke(index: i, stroke: stroke))
                for piece in pieces {
                    new.append(PlacedStroke(index: resultCount, stroke: piece))
                    resultCount += 1
                }
            } else {
                resultCount += 1
            }
        }
        return .replace(old: old, new: new)
    }

    /// Edit that bakes `transform` into the strokes with `ids` (lasso move/resize).
    public func transformEdit(_ ids: [StrokeID], by transform: CGAffineTransform) throws(PageEditError) -> PageEdit {
        _ = try Self.indices(of: ids, in: strokes)
        let det = transform.a * transform.d - transform.b * transform.c
        guard det != 0, det.isFinite else { throw .nonInvertibleTransform }
        return .transform(ids, forward: transform, backward: transform.inverted())
    }

    /// Edit that sets the color of the strokes with `ids`, recording their prior colors.
    public func recolorEdit(_ ids: [StrokeID], to color: InkColor) throws(PageEditError) -> PageEdit {
        try .recolor(zip(ids, Self.indices(of: ids, in: strokes)).map { ColorChange(id: $0, from: strokes[$1].color, to: color) })
    }

    // MARK: Private

    private static func indices(of ids: [StrokeID], in strokes: [Stroke]) throws(PageEditError) -> [Int] {
        var lookup: [StrokeID: Int] = [:]
        lookup.reserveCapacity(strokes.count)
        for (i, stroke) in strokes.enumerated() {
            lookup[stroke.id] = i
        }
        var seen = Set<StrokeID>()
        var out: [Int] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard seen.insert(id).inserted else { throw .duplicateStroke(id) }
            guard let i = lookup[id] else { throw .unknownStroke(id) }
            out.append(i)
        }
        return out
    }

    private static func checkAscending(_ placed: [PlacedStroke]) throws(PageEditError) {
        for (a, b) in zip(placed, placed.dropFirst()) where a.index >= b.index {
            throw .unsortedIndices
        }
    }

    private static func insert(_ placed: [PlacedStroke], into strokes: inout [Stroke], dirty: inout CGRect) throws(PageEditError) {
        try checkAscending(placed)
        var ids = Set(strokes.map(\.id))
        for p in placed {
            guard ids.insert(p.stroke.id).inserted else { throw .duplicateStroke(p.stroke.id) }
            guard p.index >= 0, p.index <= strokes.count else { throw .indexOutOfRange(p.index) }
            strokes.insert(p.stroke, at: p.index)
            dirty = dirty.union(p.stroke.bounds)
        }
    }

    private static func remove(_ placed: [PlacedStroke], from strokes: inout [Stroke], dirty: inout CGRect) throws(PageEditError) {
        try checkAscending(placed)
        for p in placed {
            guard p.index >= 0, p.index < strokes.count else { throw .indexOutOfRange(p.index) }
            guard strokes[p.index].id == p.stroke.id else { throw .indexMismatch(index: p.index, expected: p.stroke.id) }
        }
        for p in placed.reversed() {
            dirty = dirty.union(strokes.remove(at: p.index).bounds)
        }
    }
}
