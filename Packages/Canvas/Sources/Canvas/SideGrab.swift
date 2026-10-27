import CoreGraphics
import Foundation
import InkModel

/// A page's left or right edge (#129).
public enum PageSide: Hashable, Sendable, CaseIterable {
    case left, right
}

/// Paper a notebook added each side of its original page width (#129): ``left`` is
/// ``InkModel/Notebook/leftExtension``, ``right`` the rest of the width beyond ``InkModel/Notebook/a4Portrait``.
public struct PageExtension: Hashable, Sendable {
    /// Points added left of the original page.
    public var left: CGFloat
    /// Points added right of it.
    public var right: CGFloat

    public init(left: CGFloat = 0, right: CGFloat = 0) {
        self.left = max(left, 0)
        self.right = max(right, 0)
    }

    /// `notebook`'s extensions (its width beyond A4 less what was added on the left).
    public init(notebook: Notebook) {
        self.init(
            left: notebook.leftExtension,
            right: notebook.pageSize.width - Notebook.a4Portrait.width - notebook.leftExtension
        )
    }

    /// No paper added.
    public static let none = PageExtension()

    public subscript(side: PageSide) -> CGFloat {
        get { side == .left ? left : right }
        set {
            if side == .left {
                left = max(newValue, 0)
            } else {
                right = max(newValue, 0)
            }
        }
    }
}

/// What a finished side drag asks the document for (#129): `added` points of paper on `side`
/// (negative: taken away). Widening the left side shifts every stroke right by `added`.
public struct PageWidthChange: Hashable, Sendable {
    public var side: PageSide
    public var added: CGFloat

    public init(side: PageSide, added: CGFloat) {
        self.side = side
        self.added = added
    }
}

/// The drag math of one side grab (#129), pure so it tests headlessly: the finger's outward travel in
/// page points becomes a clamped ``delta`` (paper added on ``side``; negative takes paper away). Stops:
/// inward at the original width or the furthest ink on any page, outward at ``maxExtensionFactor`` × the
/// original width per side. Shrinking waits for the ink extent (``setInkExtent(_:)``): until it is known
/// the inward stop is the current edge.
struct SideGrab: Equatable {
    /// Paper either side may add, as a multiple of the original page width (+200 %).
    static let maxExtensionFactor: CGFloat = 2
    /// Half-width of the band around an edge that starts a grab (view points).
    static let grabBand: CGFloat = 24

    let side: PageSide
    /// The notebook's width before any extension.
    let baseWidth: CGFloat
    /// Width when the grab began.
    let pageWidth: CGFloat
    /// Paper already added each side when the grab began.
    let extensions: PageExtension
    /// Page-space x range ink covers across the notebook; `nil` once known means no ink.
    private(set) var inkExtent: ClosedRange<CGFloat>?
    private(set) var knowsInk = false
    /// Paper added so far on `side` (page points, clamped).
    private(set) var delta: CGFloat = 0
    /// Where the finger is (page points outward), clamped or not.
    private(set) var travel: CGFloat = 0
    /// The drag is pinned at a stop.
    private(set) var atStop = false

    init(side: PageSide, pageWidth: CGFloat, extensions: PageExtension) {
        self.side = side
        self.pageWidth = pageWidth
        self.extensions = extensions
        baseWidth = max(pageWidth - extensions.left - extensions.right, 1)
    }

    /// Allowed `delta`.
    var range: ClosedRange<CGFloat> {
        let current = extensions[side]
        let room: CGFloat = if !knowsInk {
            0
        } else if let inkExtent {
            side == .left ? inkExtent.lowerBound : pageWidth - inkExtent.upperBound
        } else {
            current
        }
        let lower = -min(current, max(room, 0))
        let upper = max(Self.maxExtensionFactor * baseWidth - current, 0)
        return min(lower, upper) ... upper
    }

    /// Which edge a touch at `x` grabs: the nearer of `leftEdge` / `rightEdge` within ``grabBand``.
    static func side(at x: CGFloat, leftEdge: CGFloat, rightEdge: CGFloat) -> PageSide? {
        let toLeft = abs(x - leftEdge)
        let toRight = abs(x - rightEdge)
        guard min(toLeft, toRight) <= grabBand else { return nil }
        return toLeft <= toRight ? .left : .right
    }

    /// Moves to `outward` page points from where the finger went down. Returns `true` when this move
    /// ran into a stop (the moment for a haptic).
    mutating func move(outward: CGFloat) -> Bool {
        travel = outward
        let range = range
        let clamped = min(max(outward, range.lowerBound), range.upperBound)
        let hit = clamped != outward && !atStop
        atStop = clamped != outward
        delta = clamped
        return hit
    }

    /// The ink extent arrived (or there is none); `delta` is re-clamped to it.
    mutating func setInkExtent(_ extent: ClosedRange<CGFloat>?) {
        inkExtent = extent
        knowsInk = true
        let range = range
        delta = min(max(travel, range.lowerBound), range.upperBound)
        atStop = delta != travel
    }

    /// Paper left of the original page's origin while the grab is on (left grabs only; negative when
    /// taking paper away).
    var leftShift: CGFloat {
        side == .left ? delta : 0
    }

    /// Change of the page width.
    var widthDelta: CGFloat {
        delta
    }

    /// This side's extension if released now, as a percentage of the original width.
    var percent: Int {
        Int(((extensions[side] + delta) / baseWidth * 100).rounded())
    }

    /// The width tag that follows the finger, e.g. "+50 %".
    var label: String {
        "+\(percent) %"
    }

    /// The change to hand to the document on release; `nil` if nothing moved.
    var change: PageWidthChange? {
        abs(delta) < 0.5 ? nil : PageWidthChange(side: side, added: delta)
    }
}
