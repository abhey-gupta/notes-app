@testable import DesignSystem
import Testing

struct TabFitTests {
    @Test func allFitWithoutChip() {
        #expect(TabFit.visible(widths: [100, 100, 100], available: 320, spacing: 10, overflow: 50, active: 2) == [0, 1, 2])
    }

    @Test func prefixThenChip() {
        // 100 + 10 + 100 = 210 ≤ 300 − 50 − 10; a third would be 320.
        #expect(TabFit.visible(widths: [100, 100, 100, 100], available: 300, spacing: 10, overflow: 50, active: 0) == [0, 1])
    }

    @Test func activePastPrefixTakesLastSlot() {
        #expect(TabFit.visible(widths: [100, 100, 100, 100], available: 300, spacing: 10, overflow: 50, active: 3) == [0, 3])
    }

    @Test func wideActiveAlone() {
        #expect(TabFit.visible(widths: [100, 100, 220], available: 300, spacing: 10, overflow: 50, active: 2) == [2])
    }

    @Test func empty() {
        #expect(TabFit.visible(widths: [], available: 300, spacing: 10, overflow: 50, active: nil).isEmpty)
    }
}
