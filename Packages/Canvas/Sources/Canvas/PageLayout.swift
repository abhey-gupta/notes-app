import CoreGraphics
import InkModel

/// Where every page of a notebook sits in content space (ARCHITECTURE.md §5.2): a vertical stack of
/// fixed-size pages separated by ``gap``, starting at `y = 0`, plus a ``footer`` below the last page
/// (the add-page affordance). Content space is unzoomed points; the host's scroll view zooms it.
///
/// Frames are precomputed; visibility and hit queries are binary searches, so a 300-page notebook
/// costs the same per scroll frame as a 3-page one. Pages have no view objects: they are just these
/// frames, which the engine is told about.
public struct PageLayout: Hashable, Sendable {
    /// Gap between pages (pt).
    public static let defaultGap: CGFloat = 24

    /// Page size (pt), the same for every page (A4 portrait on Day 0).
    public let pageSize: CGSize
    /// Vertical gap between consecutive pages (pt).
    public let gap: CGFloat
    /// Space below the last page (pt).
    public let footer: CGFloat
    /// Pages, top to bottom.
    public private(set) var pageIDs: [PageID]
    /// Frame of each page, parallel to ``pageIDs``.
    public private(set) var frames: [CGRect] = []

    /// Creates a layout.
    public init(pageIDs: [PageID], pageSize: CGSize = Notebook.a4Portrait, gap: CGFloat = PageLayout.defaultGap, footer: CGFloat = 0) {
        self.pageIDs = pageIDs
        self.pageSize = pageSize
        self.gap = max(gap, 0)
        self.footer = max(footer, 0)
        recompute()
    }

    /// Number of pages.
    public var pageCount: Int {
        pageIDs.count
    }

    /// Size of the whole stack including the footer.
    public var contentSize: CGSize {
        CGSize(width: pageSize.width, height: (frames.last?.maxY ?? 0) + footer)
    }

    /// The footer's rect (below the last page, full content width).
    public var footerFrame: CGRect {
        let top = frames.last.map(\.maxY) ?? 0
        return CGRect(x: 0, y: top, width: pageSize.width, height: footer)
    }

    /// Frame of the page at `index`.
    public func frame(at index: Int) -> CGRect {
        frames[index]
    }

    /// Index of `id`, O(n).
    public func index(of id: PageID) -> Int? {
        pageIDs.firstIndex(of: id)
    }

    /// Pages whose frames intersect `rect` (content space), as an index range; empty when none do.
    public func visiblePages(in rect: CGRect) -> Range<Int> {
        guard !frames.isEmpty, !rect.isNull, !rect.isEmpty, rect.maxX > 0, rect.minX < pageSize.width else { return 0 ..< 0 }
        // First page whose bottom is below the rect's top; last page whose top is above its bottom.
        let lower = partition { $0.maxY <= rect.minY }
        let upper = partition { $0.minY < rect.maxY }
        return lower < upper ? lower ..< upper : lower ..< lower
    }

    /// Page containing `point` (content space), if any (gaps and margins hit nothing).
    public func page(at point: CGPoint) -> Int? {
        let i = partition { $0.maxY <= point.y }
        guard i < frames.count, frames[i].contains(point) else { return nil }
        return i
    }

    /// The page whose frame is nearest `y` (content space): the page indicator's "current" page when `y`
    /// is the viewport's vertical center. Inside a page that page; in a gap the closer neighbour.
    public func nearestPage(toY y: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        let i = partition { $0.maxY <= y }
        guard i < frames.count else { return frames.count - 1 }
        guard i > 0, y < frames[i].minY else { return i }
        return frames[i].minY - y < y - frames[i - 1].maxY ? i : i - 1
    }

    // MARK: Structure

    /// Inserts `id` at `index` (`nil` appends) and recomputes frames.
    public mutating func insertPage(_ id: PageID, at index: Int? = nil) {
        pageIDs.insert(id, at: min(max(index ?? pageIDs.count, 0), pageIDs.count))
        recompute()
    }

    /// Removes the page at `index` and recomputes frames.
    public mutating func deletePage(at index: Int) {
        guard pageIDs.indices.contains(index) else { return }
        pageIDs.remove(at: index)
        recompute()
    }

    /// Moves the page at `source` to `destination` (both in `0..<pageCount`).
    public mutating func movePage(from source: Int, to destination: Int) {
        guard pageIDs.indices.contains(source), pageIDs.indices.contains(destination), source != destination else { return }
        pageIDs.insert(pageIDs.remove(at: source), at: destination)
        recompute()
    }

    /// Replaces the page list (e.g. the manifest arrived) and recomputes frames.
    public mutating func setPages(_ ids: [PageID]) {
        pageIDs = ids
        recompute()
    }

    // MARK: Private

    private mutating func recompute() {
        let step = pageSize.height + gap
        frames = pageIDs.indices.map { i in
            CGRect(origin: CGPoint(x: 0, y: CGFloat(i) * step), size: pageSize)
        }
    }

    /// First index whose frame fails `isBefore` (frames are sorted, so `isBefore` holds for a prefix).
    private func partition(_ isBefore: (CGRect) -> Bool) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if isBefore(frames[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

extension PageLayout {
    /// The content-space rect (unzoomed points) a scroll view shows: its `bounds` (origin = content offset,
    /// in zoomed points) divided by `zoom`. The engine's canvases and the page window come from it.
    public static func contentRect(visible bounds: CGRect, zoom: CGFloat) -> CGRect {
        guard zoom > 0 else { return .null }
        return CGRect(x: bounds.minX / zoom, y: bounds.minY / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    /// Horizontal scroll offset clamped to the content's edges (insets included): with content narrower
    /// than the view (and insets that center it) the only valid offset is the centered one. Applied while
    /// zooming so a narrow page stays centered through a pinch instead of rubber-banding sideways.
    static func pinnedOffsetX(
        _ x: CGFloat, contentWidth: CGFloat, viewWidth: CGFloat, leftInset: CGFloat, rightInset: CGFloat
    ) -> CGFloat {
        let minX = -leftInset
        let maxX = max(contentWidth + rightInset - viewWidth, minX)
        return min(max(x, minX), maxX)
    }
}
