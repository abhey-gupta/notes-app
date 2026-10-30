import Library
import SwiftUI

/// Places the editor's panes (#175): each subview says where it goes with ``SplitSlot`` (a pane's side, or
/// the divider), so a pane keeps its identity when it changes sides. `presence` is how far the split is in
/// (0: the staying pane fills the editor, 1: split at `fraction`); the `mover` pane slides in from (or out
/// to) its own edge at its split size while the other pane takes the rest, so animating `presence` is the
/// whole open/close transition. Side by side or stacked by ``SplitGeometry/axis``.
struct SplitPaneLayout: Layout {
    var fraction: Double
    var presence: Double
    var mover: OpenTabs.Pane = .secondary

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(fraction, presence) }
        set {
            fraction = newValue.first
            presence = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let frames = Self.frames(in: bounds.size, fraction: fraction, presence: presence, mover: mover)
        for subview in subviews {
            let frame = switch subview[SplitSlot.self] {
            case .pane(.primary): frames.primary
            case .pane(.secondary): frames.secondary
            case .divider: frames.divider
            }
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    struct Frames {
        var primary: CGRect
        var secondary: CGRect
        var divider: CGRect
    }

    /// Pane and divider frames in an editor of `size`.
    static func frames(in size: CGSize, fraction: Double, presence: Double, mover: OpenTabs.Pane) -> Frames {
        let geometry = SplitGeometry(size: size)
        let split = geometry.frames(fraction)
        let p = CGFloat(min(max(presence, 0), 1))
        let horizontal = geometry.axis == .horizontal
        // The mover's slide: its length plus the divider, scaled by how far out it is.
        let moverFrame = mover == .primary ? split.primary : split.secondary
        let travel = (horizontal ? moverFrame.width : moverFrame.height) + SplitGeometry.dividerThickness
        let shift = (1 - p) * travel
        var primary = split.primary, secondary = split.secondary
        switch (mover, horizontal) {
        case (.secondary, true):
            secondary.origin.x += shift
            primary.size.width += shift
        case (.secondary, false):
            secondary.origin.y += shift
            primary.size.height += shift
        case (.primary, true):
            primary.origin.x -= shift
            secondary.origin.x -= shift
            secondary.size.width += shift
        case (.primary, false):
            primary.origin.y -= shift
            secondary.origin.y -= shift
            secondary.size.height += shift
        }
        // The divider sits between them, a touch area wider than the line (``SplitDivider``).
        let touch = SplitDivider.touchWidth
        let divider = horizontal
            ? CGRect(x: primary.maxX + SplitGeometry.dividerThickness / 2 - touch / 2, y: 0, width: touch, height: size.height)
            : CGRect(x: 0, y: primary.maxY + SplitGeometry.dividerThickness / 2 - touch / 2, width: size.width, height: touch)
        return Frames(primary: primary, secondary: secondary, divider: divider)
    }
}

/// Where a subview of ``SplitPaneLayout`` goes.
enum SplitSlot: LayoutValueKey {
    case pane(OpenTabs.Pane)
    case divider

    static let defaultValue = SplitSlot.pane(.primary)
}
