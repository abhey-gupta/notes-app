@testable import Canvas
import CoreGraphics
import InkModel
import Testing

struct PageLayoutTests {
    private let step: CGFloat = 866

    private func layout(_ count: Int, footer: CGFloat = 0) -> PageLayout {
        PageLayout(pageIDs: (0 ..< count).map { _ in PageID() }, footer: footer)
    }

    @Test func framesStackA4PagesWithGap() {
        let l = layout(3, footer: 100)
        #expect(l.pageSize == CGSize(width: 595, height: 842))
        #expect(l.frame(at: 0) == CGRect(x: 0, y: 0, width: 595, height: 842))
        #expect(l.frame(at: 1) == CGRect(x: 0, y: 866, width: 595, height: 842))
        #expect(l.frame(at: 2).minY == 2 * step)
        #expect(l.contentSize == CGSize(width: 595, height: 2 * 866 + 842 + 100))
        #expect(l.footerFrame == CGRect(x: 0, y: 2 * 866 + 842, width: 595, height: 100))
    }

    @Test func emptyLayout() {
        let l = layout(0, footer: 80)
        #expect(l.contentSize == CGSize(width: 595, height: 80))
        #expect(l.visiblePages(in: CGRect(x: 0, y: 0, width: 595, height: 1000)).isEmpty)
        #expect(l.nearestPage(toY: 10) == nil)
        #expect(l.page(at: CGPoint(x: 10, y: 10)) == nil)
    }

    @Test func visiblePagesByBinarySearch() {
        let l = layout(10)
        let viewport = { (y: CGFloat, h: CGFloat) in l.visiblePages(in: CGRect(x: 0, y: y, width: 595, height: h)) }
        #expect(viewport(0, 800) == 0 ..< 1)
        #expect(viewport(0, 842) == 0 ..< 1, "touching the next page's edge isn't visible")
        #expect(viewport(0, 867) == 0 ..< 2)
        #expect(viewport(845, 10) == 1 ..< 1, "a rect inside a gap shows nothing")
        #expect(viewport(800, 2000) == 0 ..< 4)
        #expect(viewport(-500, 400) == 0 ..< 0, "above the first page")
        #expect(viewport(-500, 600) == 0 ..< 1)
        #expect(viewport(9 * 866 + 100, 5000) == 9 ..< 10)
        #expect(viewport(20000, 500) == 10 ..< 10, "below the last page")
        #expect(l.visiblePages(in: CGRect(x: 700, y: 0, width: 100, height: 800)).isEmpty, "right of the pages")
    }

    /// Brute force against the binary search over many random rects.
    @Test func visiblePagesMatchesLinearScan() {
        let l = layout(57)
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 2000 {
            let y = CGFloat.random(in: -2000 ... l.contentSize.height + 2000, using: &rng)
            let h = CGFloat.random(in: 1 ... 6000, using: &rng)
            let rect = CGRect(x: 0, y: y, width: 595, height: h)
            let expected = l.frames.indices.filter { l.frames[$0].intersects(rect) }
            let found = l.visiblePages(in: rect)
            #expect(Array(found) == expected, "rect \(rect)")
        }
    }

    @Test func pageAtPoint() {
        let l = layout(3)
        #expect(l.page(at: CGPoint(x: 10, y: 10)) == 0)
        #expect(l.page(at: CGPoint(x: 10, y: 850)) == nil, "gap")
        #expect(l.page(at: CGPoint(x: 10, y: 900)) == 1)
        #expect(l.page(at: CGPoint(x: 600, y: 900)) == nil, "outside horizontally")
        #expect(l.page(at: CGPoint(x: 10, y: 5000)) == nil)
    }

    @Test func nearestPageSwitchesAtGapMidpoint() {
        let l = layout(3)
        #expect(l.nearestPage(toY: -100) == 0)
        #expect(l.nearestPage(toY: 421) == 0)
        #expect(l.nearestPage(toY: 853) == 0, "upper half of the gap")
        #expect(l.nearestPage(toY: 855) == 1, "lower half of the gap")
        #expect(l.nearestPage(toY: 866) == 1)
        #expect(l.nearestPage(toY: 99999) == 2)
    }

    /// The indicator is a pure function of the viewport center: scrolling down only ever moves it forward.
    @Test func nearestPageIsMonotonic() {
        let l = layout(20)
        var last = 0
        var y: CGFloat = -200
        while y < l.contentSize.height + 200 {
            let page = l.nearestPage(toY: y) ?? -1
            #expect(page >= last)
            #expect(page - last <= 1)
            last = page
            y += 7
        }
        #expect(last == 19)
    }

    @Test func insertDeleteMoveRecompute() {
        var l = layout(3, footer: 50)
        let ids = l.pageIDs
        let new = PageID()
        l.insertPage(new)
        #expect(l.pageIDs == ids + [new])
        #expect(l.frame(at: 3).minY == 3 * step)
        #expect(l.contentSize.height == 3 * step + 842 + 50)

        let front = PageID()
        l.insertPage(front, at: 0)
        #expect(l.pageIDs.first == front)
        #expect(l.index(of: new) == 4)
        #expect(l.frame(at: 4).minY == 4 * step)

        l.deletePage(at: 0)
        #expect(l.pageIDs == ids + [new])
        #expect(l.frames.count == 4)

        l.movePage(from: 3, to: 0)
        #expect(l.pageIDs == [new] + ids)
        #expect(l.frames == (0 ..< 4).map { CGRect(x: 0, y: CGFloat($0) * 866, width: 595, height: 842) })

        l.deletePage(at: 99)
        l.movePage(from: 0, to: 99)
        #expect(l.pageIDs == [new] + ids, "out-of-range edits are ignored")

        l.setPages([])
        #expect(l.frames.isEmpty)
        #expect(l.contentSize.height == 50)
    }
}

struct PageWindowTests {
    @Test func marginsAroundVisiblePages() {
        let w = PageWindow(visible: 5 ..< 7, pageCount: 20)
        #expect(w.visible == 5 ..< 7)
        #expect(w.engine == 4 ..< 8)
        #expect(w.resident == 2 ..< 10)
    }

    @Test func clampedAtNotebookEnds() {
        let top = PageWindow(visible: 0 ..< 1, pageCount: 100)
        #expect(top.engine == 0 ..< 2)
        #expect(top.resident == 0 ..< 4)
        let bottom = PageWindow(visible: 99 ..< 100, pageCount: 100)
        #expect(bottom.engine == 98 ..< 100)
        #expect(bottom.resident == 96 ..< 100)
        let tiny = PageWindow(visible: 0 ..< 1, pageCount: 1)
        #expect(tiny.engine == 0 ..< 1)
        #expect(tiny.resident == 0 ..< 1)
    }

    @Test func emptyVisibleRangeStillLoadsItsPage() {
        let gap = PageWindow(visible: 3 ..< 3, pageCount: 10)
        #expect(gap.engine == 2 ..< 5)
        #expect(gap.loadOrder.first == 3)
        let past = PageWindow(visible: 12 ..< 12, pageCount: 10)
        #expect(past.engine == 8 ..< 10)
        #expect(PageWindow(visible: 0 ..< 0, pageCount: 0).resident.isEmpty)
    }

    /// Open: page 1 first, then 2–3, then the rest of the window (§8).
    @Test func loadOrderVisibleFirstThenNearest() {
        #expect(PageWindow(visible: 0 ..< 1, pageCount: 50).loadOrder == [0, 1, 2, 3])
        #expect(PageWindow(visible: 10 ..< 12, pageCount: 50).loadOrder == [10, 11, 12, 9, 13, 8, 14, 7])
        let w = PageWindow(visible: 48 ..< 50, pageCount: 50)
        #expect(w.loadOrder == [48, 49, 47, 46, 45])
        #expect(Set(w.loadOrder) == Set(w.resident))
    }

    // MARK: Zoom pinning

    @Test func narrowContentStaysCentered() {
        // 1000 pt view, 600 pt page: insets of 200 center it; any offset maps to -200.
        for x: CGFloat in [-400, -200, -150, 0, 300] {
            #expect(PageLayout.pinnedOffsetX(x, contentWidth: 600, viewWidth: 1000, leftInset: 200, rightInset: 200) == -200)
        }
    }

    @Test func wideContentStaysWithinEdges() {
        /// 1000 pt view, 1600 pt page, 16 pt margins: offsets -16...616.
        func pin(_ x: CGFloat) -> CGFloat {
            PageLayout.pinnedOffsetX(x, contentWidth: 1600, viewWidth: 1000, leftInset: 16, rightInset: 16)
        }
        #expect(pin(-80) == -16)
        #expect(pin(300) == 300)
        #expect(pin(700) == 616)
    }
}
