import CoreGraphics
@testable import InkEngine
import InkEngineTestSupport
import InkModel
import Testing

struct ViewportTests {
    let pages = RenderFixtures.stackedPages(3)

    @Test func pageViewRoundTrip() {
        let viewport = Viewport(contentOffset: CGPoint(x: 10, y: 900), zoomScale: 2, size: CGSize(width: 1024, height: 1366), pages: pages)
        let second = pages[1]
        let p = CGPoint(x: 100, y: 200)
        let v = p.applying(viewport.pageToView(second))
        #expect(v == CGPoint(x: 100 * 2 - 10, y: (866 + 200) * 2 - 900))
        let back = v.applying(viewport.viewToPage(second))
        #expect(abs(back.x - p.x) < 1e-9)
        #expect(abs(back.y - p.y) < 1e-9)
        #expect(viewport.viewRect(of: second) == CGRect(x: -10, y: 866 * 2 - 900, width: 595 * 2, height: 842 * 2))
    }

    @Test func pageHitTestingAcrossThePageGap() {
        let viewport = Viewport(contentOffset: CGPoint(x: 0, y: 800), zoomScale: 1, size: CGSize(width: 800, height: 1000), pages: pages)
        #expect(viewport.page(at: CGPoint(x: 100, y: 30))?.id == pages[0].id) // content y 830
        #expect(viewport.page(at: CGPoint(x: 100, y: 55)) == nil) // content y 855: in the 24 pt gap
        #expect(viewport.page(at: CGPoint(x: 100, y: 80))?.id == pages[1].id)
        #expect(viewport.page(at: CGPoint(x: 700, y: 80)) == nil) // right of the page
        #expect(viewport.centerPage?.id == pages[1].id)
    }

    @Test func snapshotAppliesEdits() throws {
        let snapshot = RenderFixtures.blank
        let stroke = RenderFixtures.line(1, from: .zero, to: CGPoint(x: 10, y: 0))
        let edited = try snapshot.applying(snapshot.page.addEdit([stroke]))
        #expect(edited.strokes == [stroke])
        #expect(edited.rev == snapshot.rev + 1)
        #expect(edited.size == snapshot.size)
    }
}
