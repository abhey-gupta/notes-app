import DesignSystem
import SwiftUI
import Tools
import UIKit

/// One-finger pan that only accepts direct touches: Apple Pencil never moves the toolbar, it taps buttons.
///
/// UIKit-backed so `allowedTouchTypes` can exclude Pencil; translation and velocity are in window points,
/// so they don't feed back through the moving view. Once it recognizes it cancels the touch in the button
/// underneath, so a drag that starts on a tool never selects it; a tap (under 10 pt of travel) fails the pan
/// and the button gets it. A second finger (pinch) cancels the drag.
struct FingerPan: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGSize) -> Void
    /// Translation, velocity (pt/s), cancelled.
    var onEnded: (CGSize, CGSize, Bool) -> Void

    func makeUIGestureRecognizer(context _: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context _: Context) {
        let point = pan.translation(in: nil)
        let speed = pan.velocity(in: nil)
        let translation = CGSize(width: point.x, height: point.y)
        let velocity = CGSize(width: speed.x, height: speed.y)
        switch pan.state {
        case .began:
            onBegan()
            onChanged(translation)
        case .changed:
            if pan.numberOfTouches > 1 {
                // Toggling `isEnabled` cancels; the `.cancelled` callback springs the toolbar home.
                pan.isEnabled = false
                pan.isEnabled = true
            } else {
                onChanged(translation)
            }
        case .ended:
            onEnded(translation, velocity, false)
        case .cancelled, .failed:
            onEnded(translation, velocity, true)
        default:
            break
        }
    }
}

/// Two-finger pinch over the toolbar, reporting magnification (1 = fingers where they started).
///
/// UIKit-backed: SwiftUI's `MagnifyGesture` (and a stock `UIPinchGestureRecognizer`) on the capsule is
/// prevented by SwiftUI's touch-forwarding recognizer for the buttons under the fingers and never fires.
struct FingerPinch: UIGestureRecognizerRepresentable {
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: (CGFloat) -> Void

    func makeUIGestureRecognizer(context _: Context) -> UIPinchGestureRecognizer {
        let pinch = UnpreventablePinch()
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        return pinch
    }

    func handleUIGestureRecognizerAction(_ pinch: UIPinchGestureRecognizer, context _: Context) {
        switch pinch.state {
        case .began, .changed:
            onChanged(pinch.scale)
        case .ended:
            onEnded(pinch.scale)
        case .cancelled, .failed:
            onEnded(1)
        default:
            break
        }
    }
}

/// A pinch the buttons' touch forwarding can't prevent (see ``FingerPinch``).
private final class UnpreventablePinch: UIPinchGestureRecognizer {
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool {
        false
    }
}

/// Pure geometry for the dynamic toolbar (§7): nearest dock, edge rubber-banding, top-row fitting.
enum DockGeometry {
    /// Release velocity is projected this far ahead (s) so a flick toward an edge docks there.
    static let flickProjection: CGFloat = 0.15
    /// Bias toward the current target so the hint doesn't flicker on a diagonal.
    static let hysteresis: CGFloat = 0.03

    /// Dock whose edge is nearest to `point`, distances normalized by `bounds` so the diagonals split the
    /// screen into four equal-feeling triangles regardless of orientation.
    static func nearestDock(to point: CGPoint, in bounds: CGRect, current: ToolbarDock? = nil) -> ToolbarDock {
        guard bounds.width > 0, bounds.height > 0 else { return current ?? .top }
        let fx = (point.x - bounds.minX) / bounds.width
        let fy = (point.y - bounds.minY) / bounds.height
        let distances: [(ToolbarDock, CGFloat)] = [(.top, fy), (.bottom, 1 - fy), (.left, fx), (.right, 1 - fx)]
        return distances.reduce((current ?? .top, CGFloat.infinity)) { best, candidate in
            let distance = candidate.1 - (candidate.0 == current ? hysteresis : 0)
            return distance < best.1 ? (candidate.0, distance) : best
        }.0
    }

    /// `translation` for a toolbar at `frame`, with UIScrollView-style resistance past `bounds`.
    static func rubberBanded(_ translation: CGSize, frame: CGRect, in bounds: CGRect, limit: CGFloat = 24) -> CGSize {
        CGSize(
            width: band(translation.width, lower: bounds.minX - frame.minX, upper: bounds.maxX - frame.maxX, limit: limit),
            height: band(translation.height, lower: bounds.minY - frame.minY, upper: bounds.maxY - frame.maxY, limit: limit)
        )
    }

    /// Pinch feedback: shrinks at under half the finger rate, barely grows.
    static func pinchScale(_ magnification: CGFloat) -> CGFloat {
        magnification < 1 ? max(1 - (1 - magnification) * 0.45, 0.8) : 1 + resist(magnification - 1, limit: 0.04)
    }

    /// Horizontal shift that keeps a `width`-wide toolbar centred in `container` but clear of `leading` and
    /// `trailing` reserved widths (the nav and pages capsules). `nil` when the row has no room.
    static func rowShift(width: CGFloat, in container: CGFloat, leading: CGFloat, trailing: CGFloat, gap: CGFloat) -> CGFloat? {
        let lower = leading > 0 ? leading + gap : 0
        let upper = container - (trailing > 0 ? trailing + gap : 0)
        guard upper - lower >= width else { return nil }
        let center = min(max(container / 2, lower + width / 2), upper - width / 2)
        return center - container / 2
    }

    private static func band(_ value: CGFloat, lower: CGFloat, upper: CGFloat, limit: CGFloat) -> CGFloat {
        guard lower <= upper else { return (lower + upper) / 2 }
        if value < lower {
            return lower - resist(lower - value, limit: limit)
        }
        if value > upper {
            return upper + resist(value - upper, limit: limit)
        }
        return value
    }

    /// Approaches `limit` asymptotically (UIScrollView's 0.55 coefficient).
    private static func resist(_ overshoot: CGFloat, limit: CGFloat) -> CGFloat {
        (1 - 1 / (overshoot * 0.55 / limit + 1)) * limit
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension CGPoint {
    static func + (point: CGPoint, offset: CGSize) -> CGPoint {
        CGPoint(x: point.x + offset.width, y: point.y + offset.height)
    }
}

extension CGSize {
    static func * (size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    var transposed: CGSize {
        CGSize(width: height, height: width)
    }
}

/// VoiceOver order of the editor chrome (higher first), whatever the dock (#45).
enum ChromeOrder {
    static let nav: Double = 4
    static let tools: Double = 3
    static let pages: Double = 2
    static let pagePill: Double = 1
}

/// Where the toolbar rests at each dock (§7), from the chrome's measured geometry.
struct DockLayout {
    var containerWidth: CGFloat
    /// Nav and pages capsule widths; 0 when hidden (focus mode).
    var nav: CGFloat
    var pages: CGFloat
    var pagePill: CGSize
    var isCompact: Bool
    var isFocused: Bool
    /// Dynamic Type chrome scale (``DynamicTypeSize/chromeScale``): capsules are thicker at large sizes.
    var scale: CGFloat = 1

    struct Placement {
        var insets = EdgeInsets()
        /// Horizontal nudge keeping a top/bottom toolbar clear of the neighbouring capsules.
        var shift: CGFloat = 0
    }

    /// Padding and nudge that put a `length`-long toolbar at `dock`:
    /// - top: centred under the status bar, clear of the nav (left) and pages (right) capsules; on a row too
    ///   narrow for all three it drops below them.
    /// - bottom: centred above the home indicator, clear of the page pill.
    /// - left/right: vertically centred between the top capsules and the page pill.
    /// The compact pill is inset so its centre line matches the expanded capsule's.
    func placement(for dock: ToolbarDock, length: CGFloat) -> Placement {
        let spacing = Tokens.Spacing.self
        let capsule = Tokens.Size.capsuleHeight * scale
        let pillInset = isCompact ? (capsule - Tokens.Size.focusPillHeight * scale) / 2 : 0
        let belowTopRow = spacing.s + capsule + spacing.m
        let abovePagePill = spacing.chromeInset + pagePill.height + spacing.m
        switch dock {
        case .top:
            if let shift = DockGeometry.rowShift(width: length, in: containerWidth, leading: nav, trailing: pages, gap: spacing.m) {
                return Placement(insets: EdgeInsets(top: spacing.s + pillInset, leading: 0, bottom: 0, trailing: 0), shift: shift)
            }
            return Placement(insets: EdgeInsets(top: belowTopRow + pillInset, leading: 0, bottom: 0, trailing: 0))
        case .bottom:
            let row = DockGeometry.rowShift(width: length, in: containerWidth, leading: 0, trailing: pagePill.width, gap: spacing.m)
            if let shift = row {
                return Placement(insets: EdgeInsets(top: 0, leading: 0, bottom: spacing.chromeInset + pillInset, trailing: 0), shift: shift)
            }
            return Placement(insets: EdgeInsets(top: 0, leading: 0, bottom: abovePagePill + pillInset, trailing: 0))
        case .left, .right:
            return Placement(insets: EdgeInsets(
                top: isFocused ? spacing.s : belowTopRow,
                leading: dock == .left ? pillInset : 0,
                bottom: abovePagePill,
                trailing: dock == .right ? pillInset : 0
            ))
        }
    }
}

extension View {
    /// Glass morph identity of an editor chrome piece.
    func chromeID(_ id: ToolbarHost.ChromeID, in namespace: Namespace.ID, transition: GlassEffectTransition) -> some View {
        glassEffectID(id, in: namespace)
            .glassEffectTransition(transition)
    }
}
