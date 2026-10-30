import CoreGraphics

/// Split view geometry (#175): where the two panes and the divider sit in the editor, the divider's
/// stops, and when a drag toward an edge closes the pane there. Side by side when the editor is wider than
/// it is tall, stacked (primary on top) otherwise, so a page keeps its writing width in portrait.
///
/// Fractions are the primary pane's share of the editor's length along the split axis.
public struct SplitGeometry: Hashable, Sendable {
    public enum Axis: Hashable, Sendable {
        /// Side by side: primary leading, secondary trailing.
        case horizontal
        /// Stacked: primary on top.
        case vertical
    }

    /// Where a released divider goes.
    public enum Release: Hashable, Sendable {
        /// Rests at this fraction (one of ``stops``).
        case rest(Double)
        /// The pane is dragged away: the split ends, the other pane keeps the editor.
        case close(OpenTabs.Pane)
    }

    public static let half = 0.5
    /// Where the divider rests: ⅓, ½, ⅔.
    public static let stops = [1.0 / 3, half, 2.0 / 3]
    /// The divider line between the panes (pt).
    public static let dividerThickness: CGFloat = 1
    /// A pane dragged under this share of the editor closes on release.
    public static let closeThreshold = 0.15
    /// While dragging, the divider clings to a stop within this distance (pt).
    public static let snapDistance: CGFloat = 24
    /// How far a release's velocity carries the divider (s): a flick lands where it was heading.
    public static let projection: CGFloat = 0.12

    public let size: CGSize

    public init(size: CGSize) {
        self.size = size
    }

    public var axis: Axis {
        size.width >= size.height ? .horizontal : .vertical
    }

    /// The editor's length along the split axis.
    public var length: CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    /// The divider's position along the axis for `fraction`, on whole points.
    public func position(_ fraction: Double) -> CGFloat {
        (length * CGFloat(fraction)).rounded()
    }

    /// The panes' frames, the divider between them.
    public func frames(_ fraction: Double) -> (primary: CGRect, secondary: CGRect) {
        let split = position(fraction)
        let after = split + Self.dividerThickness
        switch axis {
        case .horizontal:
            return (
                CGRect(x: 0, y: 0, width: split, height: size.height),
                CGRect(x: after, y: 0, width: max(size.width - after, 0), height: size.height)
            )
        case .vertical:
            return (
                CGRect(x: 0, y: 0, width: size.width, height: split),
                CGRect(x: 0, y: after, width: size.width, height: max(size.height - after, 0))
            )
        }
    }

    /// The divider under a finger at `position` (pt along the axis): it follows, clinging to a stop within
    /// ``snapDistance``. Returns the fraction and the stop it clings to, if any.
    public func drag(to position: CGFloat) -> (fraction: Double, stop: Double?) {
        guard length > 0 else { return (Self.half, nil) }
        let clamped = min(max(position, 0), length)
        if let stop = Self.stops.first(where: { abs(self.position($0) - clamped) <= Self.snapDistance }) {
            return (stop, stop)
        }
        return (Double(clamped / length), nil)
    }

    /// Where the divider goes when released at `position` moving at `velocity` (pt/s along the axis): the
    /// stop nearest to where the flick was heading, or a pane closes when that's within ``closeThreshold``
    /// of its edge.
    public func release(at position: CGFloat, velocity: CGFloat) -> Release {
        guard length > 0 else { return .rest(Self.half) }
        let projected = Double((position + velocity * Self.projection) / length)
        if projected < Self.closeThreshold {
            return .close(.primary)
        }
        if projected > 1 - Self.closeThreshold {
            return .close(.secondary)
        }
        let stop = Self.stops.min { abs($0 - projected) < abs($1 - projected) } ?? Self.half
        return .rest(stop)
    }

    /// How far `fraction` has gone into a close zone (0 outside, 1 at the edge), and which pane is going.
    public func closing(_ fraction: Double) -> (pane: OpenTabs.Pane, progress: Double)? {
        if fraction < Self.closeThreshold {
            return (.primary, 1 - fraction / Self.closeThreshold)
        }
        if fraction > 1 - Self.closeThreshold {
            return (.secondary, (fraction - (1 - Self.closeThreshold)) / Self.closeThreshold)
        }
        return nil
    }
}
