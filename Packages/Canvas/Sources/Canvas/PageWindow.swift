/// Which pages need what, given the visible ones (ARCHITECTURE.md §5.4 residency):
///
/// - ``engine``: visible ± ``engineMargin`` pages get stroke snapshots in the engine (scrolling one page
///   never shows a page the engine hasn't seen).
/// - ``resident``: visible ± ``residentMargin`` pages keep their strokes in memory; the rest are evicted
///   (checkpointed and dropped) and reload from disk on demand.
///
/// Pure value; ``loadOrder`` is the order to load missing pages in (visible first, then outwards).
public struct PageWindow: Hashable, Sendable {
    /// Pages around the visible ones that the engine holds.
    public static let engineMargin = 1
    /// Pages around the visible ones kept in memory.
    public static let residentMargin = 3

    /// Pages on screen.
    public let visible: Range<Int>
    /// Pages handed to the engine.
    public let engine: Range<Int>
    /// Pages kept in memory.
    public let resident: Range<Int>

    /// Creates the window for `visible` pages of a `pageCount`-page notebook. An empty `visible` range
    /// (nothing on screen yet) is treated as its lower bound's page, clamped, so a notebook always has a
    /// page loading.
    public init(
        visible: Range<Int>,
        pageCount: Int,
        engineMargin: Int = PageWindow.engineMargin,
        residentMargin: Int = PageWindow.residentMargin
    ) {
        guard pageCount > 0 else {
            self.visible = 0 ..< 0
            engine = 0 ..< 0
            resident = 0 ..< 0
            return
        }
        let first = min(max(visible.lowerBound, 0), pageCount - 1)
        let last = visible.isEmpty ? first : min(max(visible.upperBound - 1, first), pageCount - 1)
        self.visible = visible.isEmpty ? first ..< first : first ..< last + 1
        func around(_ margin: Int) -> Range<Int> {
            max(first - max(margin, 0), 0) ..< min(last + 1 + max(margin, 0), pageCount)
        }
        engine = around(engineMargin)
        resident = around(max(residentMargin, engineMargin))
    }

    /// Resident pages ordered by priority: visible top to bottom, then alternately below and above,
    /// nearest first (after page 1: 2, 3, 4…).
    public var loadOrder: [Int] {
        let anchor = visible.isEmpty ? visible.lowerBound ..< visible.lowerBound + 1 : visible
        var order = Array(anchor.clamped(to: resident))
        var below = anchor.upperBound
        var above = anchor.lowerBound - 1
        while below < resident.upperBound || above >= resident.lowerBound {
            if below < resident.upperBound {
                order.append(below)
                below += 1
            }
            if above >= resident.lowerBound {
                order.append(above)
                above -= 1
            }
        }
        return order
    }
}
