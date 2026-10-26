@testable import Canvas
import CoreGraphics
import InkModel
import Testing

/// Page-width handle drags (#129): 25 % steps of the original width, up to 200 % per side, never below
/// the original width nor past the furthest ink.
struct PageWidthDragTests {
    private let width: CGFloat = 400 // one step = 100 pt

    @Test func layoutWidensEveryPage() {
        let l = PageLayout(
            pageIDs: [PageID(), PageID()], pageSize: CGSize(width: 400, height: 500),
            pageExtension: PageExtension(left: 100, right: 200)
        )
        #expect(l.basePageSize == CGSize(width: 400, height: 500))
        #expect(l.pageSize == CGSize(width: 700, height: 500))
        #expect(l.frame(at: 1) == CGRect(x: 0, y: 524, width: 700, height: 500))
        #expect(l.contentSize.width == 700)
    }

    @Test func dragOutSnapsToSteps() {
        let drag = PageWidthDrag(side: .right, baseWidth: width, start: .none, inkSpan: nil)
        #expect(drag.steps(for: 40) == (0, nil))
        #expect(drag.steps(for: 60) == (1, nil))
        #expect(drag.steps(for: 190) == (2, nil))
        #expect(drag.pageExtension(steps: 2) == PageExtension(right: 200))
        #expect(drag.edgeOffset(steps: 2) == 200)
        #expect(PageWidthDrag.label(steps: 2) == "+50%")
    }

    @Test func leftDragsGoLeft() {
        let drag = PageWidthDrag(side: .left, baseWidth: width, start: PageExtension(right: 100), inkSpan: nil)
        #expect(drag.steps(for: -300) == (3, nil))
        #expect(drag.steps(for: 300) == (0, .original))
        #expect(drag.pageExtension(steps: 3) == PageExtension(left: 300, right: 100))
        #expect(drag.edgeOffset(steps: 3) == -300)
    }

    @Test func maximumIsTwiceTheWidthPerSide() {
        let drag = PageWidthDrag(side: .right, baseWidth: width, start: .none, inkSpan: nil)
        #expect(drag.steps(for: 5000) == (8, .maximum))
        #expect(PageWidthDrag.label(steps: 8) == "+200%")
    }

    @Test func shrinkingStopsAtTheOriginalWidth() {
        let drag = PageWidthDrag(side: .right, baseWidth: width, start: PageExtension(right: 200), inkSpan: nil)
        #expect(drag.steps(for: -200) == (0, nil))
        #expect(drag.steps(for: -400) == (0, .original))
    }

    @Test func shrinkingStopsAtTheFurthestInk() {
        // Page space starts at the widened left edge: original page is 100...500, ink reaches x = 640.
        let start = PageExtension(left: 100, right: 300)
        let right = PageWidthDrag(side: .right, baseWidth: width, start: start, inkSpan: 150 ... 640)
        #expect(right.minimumSteps == 2, "140 pt into the extension needs two steps")
        #expect(right.steps(for: -100) == (2, nil))
        #expect(right.steps(for: -300) == (2, .ink))
        let left = PageWidthDrag(side: .left, baseWidth: width, start: start, inkSpan: 150 ... 640)
        #expect(left.minimumSteps == 0, "ink starts right of the original edge")
        #expect(left.steps(for: 300) == (0, .original))
    }

    @Test func unmeasuredInkKeepsTheSide() {
        let drag = PageWidthDrag(side: .left, baseWidth: width, start: PageExtension(left: 200), inkSpan: -.infinity ... .infinity)
        #expect(drag.minimumSteps == 2)
        #expect(drag.steps(for: 300) == (2, .ink))
        #expect(drag.steps(for: -100) == (3, nil), "growing still works")
    }
}
