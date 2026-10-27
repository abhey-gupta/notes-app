@testable import Canvas
import CoreGraphics
import InkModel
import Testing

/// Side-drag math (#129): continuous, clamped at the ink and at +200 % per side.
struct SideGrabTests {
    @Test func extensionsComeFromTheNotebook() {
        let plain = Notebook(title: "a")
        #expect(PageExtension(notebook: plain) == .none)
        var wide = plain
        wide.pageSize.width = 595 + 100 + 250
        wide.leftExtension = 100
        #expect(PageExtension(notebook: wide) == PageExtension(left: 100, right: 250))
    }

    @Test func grabsTheNearerEdgeWithinTheBand() {
        #expect(SideGrab.side(at: 10, leftEdge: 0, rightEdge: 600) == .left)
        #expect(SideGrab.side(at: -20, leftEdge: 0, rightEdge: 600) == .left)
        #expect(SideGrab.side(at: 590, leftEdge: 0, rightEdge: 600) == .right)
        #expect(SideGrab.side(at: 300, leftEdge: 0, rightEdge: 600) == nil)
        #expect(SideGrab.side(at: 25, leftEdge: 0, rightEdge: 600) == nil, "just outside the 24 pt band")
    }

    @Test func outwardDragIsContinuousAndStopsAtTwoHundredPercent() {
        var grab = SideGrab(side: .right, pageWidth: 595, extensions: .none)
        let stop1 = grab.move(outward: 37.3)
        #expect(!stop1)
        #expect(grab.delta == 37.3, "any width, no steps")
        #expect(grab.label == "+6 %")
        let stop2 = grab.move(outward: 1500)
        #expect(stop2, "hits the +200 % stop")
        #expect(grab.delta == 1190)
        #expect(grab.label == "+200 %")
        let stop3 = grab.move(outward: 1600)
        #expect(!stop3, "still pinned: no second haptic")
        let stop4 = grab.move(outward: 1000)
        #expect(!stop4, "off the stop")
        #expect(grab.change == PageWidthChange(side: .right, added: 1000))
    }

    @Test func inwardDragWaitsForTheInkThenStopsAtIt() {
        var grab = SideGrab(side: .right, pageWidth: 795, extensions: PageExtension(left: 0, right: 200))
        let stop5 = grab.move(outward: -50)
        #expect(stop5, "until the ink extent is known the edge can't move in")
        #expect(grab.delta == 0)
        grab.setInkExtent(50 ... 700)
        #expect(grab.delta == -50, "re-clamped once known: 95 pt of empty paper on the right")
        let stop6 = grab.move(outward: -60)
        #expect(!stop6)
        let stop7 = grab.move(outward: -300)
        #expect(stop7, "stops at the furthest ink")
        #expect(grab.delta == -95)
        #expect(grab.label == "+18 %")
    }

    @Test func inwardDragNeverGoesBelowTheOriginalWidth() {
        var grab = SideGrab(side: .left, pageWidth: 695, extensions: PageExtension(left: 100, right: 0))
        grab.setInkExtent(nil)
        let stop8 = grab.move(outward: -400)
        #expect(stop8)
        #expect(grab.delta == -100, "all the added paper, none of the original")
        #expect(grab.leftShift == -100)
        #expect(grab.change == PageWidthChange(side: .left, added: -100))
        var original = SideGrab(side: .left, pageWidth: 595, extensions: .none)
        original.setInkExtent(nil)
        let stop9 = original.move(outward: -10)
        #expect(stop9)
        #expect(original.delta == 0)
        #expect(original.change == nil)
    }

    @Test func leftInkLimitsTheLeftSide() {
        var grab = SideGrab(side: .left, pageWidth: 795, extensions: PageExtension(left: 200, right: 0))
        grab.setInkExtent(120 ... 500)
        _ = grab.move(outward: -500)
        #expect(grab.delta == -120, "the ink starts 120 pt in: that much paper can go")
    }
}
