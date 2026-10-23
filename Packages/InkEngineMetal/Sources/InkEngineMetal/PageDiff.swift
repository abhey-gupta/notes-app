import CoreGraphics
import InkEngine
import InkModel

/// What changed between two builds of a page, for rect-based tile invalidation (ARCHITECTURE.md §5.4).
enum PageDiff {
    /// Page-space rect whose pixels may differ from `old` to `new`: `.null` if none, `nil` if the whole
    /// page (theme, template or size changed, or strokes were reordered).
    ///
    /// Strokes are matched by ID; added, removed or changed strokes contribute their strip bounds
    /// (AA fringe included) from the build that drew them. Highlighter grouping needs nothing extra:
    /// multiply/screen commute, so a highlighter only affects pixels within its own bounds.
    static func dirtyRect(from old: PageBuffers, to new: PageBuffers) -> CGRect? {
        guard old.theme == new.theme, old.snapshot.page.template == new.snapshot.page.template,
              old.snapshot.size == new.snapshot.size else { return nil }
        let before = old.snapshot.strokes
        let after = new.snapshot.strokes
        var previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var dirty = CGRect.null
        var common: [StrokeID] = []
        common.reserveCapacity(after.count)
        for stroke in after {
            if let was = previous.removeValue(forKey: stroke.id) {
                common.append(stroke.id)
                if was != stroke {
                    dirty = dirty.union(old.bounds(of: was.id) ?? was.bounds).union(new.bounds(of: stroke.id) ?? stroke.bounds)
                }
            } else {
                dirty = dirty.union(new.bounds(of: stroke.id) ?? stroke.bounds)
            }
        }
        for (id, was) in previous {
            dirty = dirty.union(old.bounds(of: id) ?? was.bounds)
        }
        // Same strokes in a different z-order: whole page (no edit does this today).
        let kept = Set(common)
        guard before.lazy.map(\.id).filter(kept.contains).elementsEqual(common) else { return nil }
        return dirty
    }
}

/// Identifies a page's committed look without holding its strokes: when a dropped page (beyond the
/// ± 3 window) is rebuilt with the same signature, its cached tiles are still valid.
struct PageSignature: Equatable {
    var rev: UInt64
    var strokeCount: Int
    var theme: PaperTheme
    var template: PageTemplate
    var size: CGSize

    init(_ buffers: PageBuffers) {
        rev = buffers.snapshot.rev
        strokeCount = buffers.snapshot.strokes.count
        theme = buffers.theme
        template = buffers.snapshot.page.template
        size = buffers.snapshot.size
    }
}
