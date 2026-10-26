import Canvas
import Foundation
import Testing

/// When a two- or three-finger tap undoes/redoes (#121).
struct MultiFingerTapRuleTests {
    @Test func quickStillTapCounts() {
        #expect(MultiFingerTapRule().accepts(began: 10, ended: 10.1, navigated: false))
        #expect(MultiFingerTapRule().accepts(began: 10, ended: 10.25, navigated: false))
    }

    @Test func slowTapIsIgnored() {
        #expect(!MultiFingerTapRule().accepts(began: 10, ended: 10.31, navigated: false))
    }

    @Test func scrollZoomOrStoppingAFlingIsIgnored() {
        #expect(!MultiFingerTapRule().accepts(began: 10, ended: 10.1, navigated: true))
    }

    @Test func pencilDownIsIgnored() {
        #expect(!MultiFingerTapRule(pencilsDown: 1).accepts(began: 10, ended: 10.1, navigated: false))
    }

    @Test func fingersRightAfterPencilAreAPalm() {
        #expect(!MultiFingerTapRule(lastPencilUp: 9.8).accepts(began: 10, ended: 10.1, navigated: false))
        #expect(!MultiFingerTapRule(lastPencilUp: 10.05).accepts(began: 10, ended: 10.1, navigated: false))
        #expect(MultiFingerTapRule(lastPencilUp: 9.4).accepts(began: 10, ended: 10.1, navigated: false))
    }
}
