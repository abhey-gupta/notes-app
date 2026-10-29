import CoreGraphics

/// Which tabs a strip shows (#191): tabs never shrink below their full title, so the strip shows the
/// longest prefix that fits and folds the rest into a "+N" chip.
public enum TabFit {
    /// Indices of the tabs to show, in order.
    ///
    /// - Parameters:
    ///   - widths: natural width of each tab.
    ///   - available: room for tabs and, when not all fit, the overflow chip.
    ///   - spacing: between tabs (and before the chip).
    ///   - overflow: the chip's width.
    ///   - active: the showing tab, always visible: when it falls past the prefix it takes the last slot.
    public static func visible(widths: [CGFloat], available: CGFloat, spacing: CGFloat, overflow: CGFloat, active: Int?) -> [Int] {
        guard !widths.isEmpty else { return [] }
        if total(widths.indices, widths: widths, spacing: spacing) <= available {
            return Array(widths.indices)
        }
        let budget = available - overflow - spacing
        var shown: [Int] = []
        for index in widths.indices {
            let candidate = shown + [index]
            guard total(candidate, widths: widths, spacing: spacing) <= budget else { break }
            shown = candidate
        }
        if let active, widths.indices.contains(active), !shown.contains(active) {
            while !shown.isEmpty, total(shown + [active], widths: widths, spacing: spacing) > budget {
                shown.removeLast()
            }
            shown.append(active)
        }
        return shown
    }

    private static func total(_ indices: some Collection<Int>, widths: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !indices.isEmpty else { return 0 }
        return indices.reduce(0) { $0 + widths[$1] } + spacing * CGFloat(indices.count - 1)
    }
}
