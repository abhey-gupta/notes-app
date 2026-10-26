import CoreGraphics
import InkModel

/// One drag of a page-width handle (#129): where the dragged edge lands, in whole
/// ``InkModel/PageExtension/step``s of the original width. Out to ``InkModel/PageExtension/maximum``;
/// in, never past the original edge nor past the ink furthest out on that side on any page.
public struct PageWidthDrag: Hashable, Sendable {
    /// What stopped the edge.
    public enum Limit: Hashable, Sendable {
        /// The original page edge.
        case original
        /// Ink in the extension.
        case ink
        /// ``InkModel/PageExtension/maximum``.
        case maximum
    }

    /// The edge being dragged.
    public let side: PageExtension.Side
    /// The original page width (pt).
    public let baseWidth: CGFloat
    /// The extension when the drag began.
    public let start: PageExtension
    /// Fewest steps the side can keep: the ink furthest out on that side stays on the page.
    public let minimumSteps: Int

    /// - Parameter inkSpan: Left and right edges of all ink on every page (page space), `nil` if none.
    ///   `-.infinity ... .infinity` (ink not measured yet) keeps the side from shrinking at all.
    public init(side: PageExtension.Side, baseWidth: CGFloat, start: PageExtension, inkSpan: ClosedRange<CGFloat>?) {
        self.side = side
        self.baseWidth = baseWidth
        self.start = start
        let startSteps = start.steps(side, of: baseWidth)
        var needed = 0
        if let inkSpan, baseWidth > 0 {
            // How far the ink reaches past the original edge on this side.
            let reach = side == .left ? start.left - inkSpan.lowerBound : inkSpan.upperBound - (start.left + baseWidth)
            let steps = min(reach / (PageExtension.step * baseWidth), CGFloat(PageExtension.maximumSteps + 1))
            needed = Int((steps - 0.001).rounded(.up))
        }
        // Ink already off the page can't make the page grow by itself; it only stops shrinking.
        minimumSteps = min(max(needed, 0), startSteps)
    }

    /// Steps for a drag of `translation` pt (content space, positive rightward), and the limit the drag
    /// pushes past (`nil` while it's free).
    public func steps(for translation: CGFloat) -> (steps: Int, limit: Limit?) {
        guard baseWidth > 0 else { return (0, .original) }
        let outward = side == .left ? -translation : translation
        let raw = Int(((start[side] + outward) / (PageExtension.step * baseWidth)).rounded())
        if raw > PageExtension.maximumSteps {
            return (PageExtension.maximumSteps, .maximum)
        }
        if raw < minimumSteps {
            return (minimumSteps, minimumSteps > 0 ? .ink : .original)
        }
        return (raw, nil)
    }

    /// The extension with this drag's side at `steps`.
    public func pageExtension(steps: Int) -> PageExtension {
        var next = start
        next[side] = CGFloat(steps) * PageExtension.step * baseWidth
        return next
    }

    /// How far (pt, positive rightward) the dragged edge sits from where it began, at `steps`.
    public func edgeOffset(steps: Int) -> CGFloat {
        let delta = pageExtension(steps: steps)[side] - start[side]
        return side == .left ? -delta : delta
    }

    /// The width tag: `"+50%"` (this side's extension as a share of the original width).
    public static func label(steps: Int) -> String {
        "+\(Int((CGFloat(steps) * PageExtension.step * 100).rounded()))%"
    }
}
