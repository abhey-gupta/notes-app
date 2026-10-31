import Canvas
import DesignSystem
import os
import QuartzCore
import SwiftUI
import UIKit

/// Timing of the pages overview's zoom-to-cell transition (#124). Everything is a segment of one
/// 350 ms flight, played backwards on close, so open and close mirror each other exactly.
enum FlightTiming {
    static let duration: TimeInterval = 0.35
    static let bounce: CGFloat = 0.12
    /// Reduce Motion: nothing flies, everything crossfades.
    static let reduced: TimeInterval = 0.15

    /// The part of the flight (fractions `from`...`to` of ``duration``) an element animates in.
    static func segment(_ from: Double, _ to: Double, opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion {
            return .easeInOut(duration: reduced)
        }
        let to = min(to, 1)
        let length = max(to - from, 0.05) * duration
        let delay = max(opening ? from : 1 - to, 0) * duration
        return .easeOut(duration: length).delay(delay)
    }

    /// Ripple: a cell `distance` cells from the current one starts 25 ms later per cell (capped).
    static func rippleDelay(distance: Int) -> Double {
        Double(min(distance, 4)) * 0.07
    }
}

/// The page in flight between the canvas and its grid cell: a snapshot view of what the user sees of
/// the page (`PageCapture`) over its thumbnail, in a clipping container whose geometry, corners and
/// shadow spring from one pose to the other on the render server (no per-frame work on the main
/// thread). The overview places it over everything and fades its SwiftUI parts in step (`FlightTiming`).
@MainActor
final class PageFlightView: UIView {
    /// One end of the flight, in this view's coordinates.
    struct Pose {
        /// The clipping container.
        var container: CGRect
        /// The visible-part snapshot and the thumbnail, container-local.
        var snapshot: CGRect
        var thumb: CGRect
        var radius: CGFloat
        var shadowOpacity: Float
    }

    private let shadow = CALayer()
    private let container = UIView()
    private let thumb = CALayer()
    /// The capture's snapshot view, a subview of `container` above `thumb`.
    private var snapshot: UIView?
    private(set) var isFlying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        container.layer.masksToBounds = true
        container.layer.cornerCurve = .continuous
        container.layer.allowsEdgeAntialiasing = true
        container.isUserInteractionEnabled = false
        thumb.contentsGravity = .resize
        let token = Tokens.Shadows.thumb
        shadow.shadowColor = token.color.uiColor.cgColor
        shadow.shadowOffset = CGSize(width: token.x, height: token.y)
        shadow.shadowRadius = token.radius
        shadow.shadowOpacity = 0
        container.layer.addSublayer(thumb)
        layer.addSublayer(shadow)
        addSubview(container)
        setHidden(true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: Poses

    /// The page where it is on screen: the container is the visible part, the thumbnail region sits
    /// top-left of the page behind it. `capture` frames are window coordinates; `thumb` is the cell's size.
    func pagePose(_ capture: PageCapture, thumb: CGSize) -> Pose {
        let page = convert(capture.pageFrame, from: nil)
        let visible = convert(capture.visibleFrame, from: nil)
        let scale = Self.thumbScale(pageSize: page.size, thumb: thumb)
        let thumbSize = CGSize(width: thumb.width / scale, height: thumb.height / scale)
        let origin = CGPoint(x: page.minX - visible.minX, y: page.minY - visible.minY)
        return Pose(
            container: visible,
            snapshot: CGRect(origin: .zero, size: visible.size),
            thumb: CGRect(origin: origin, size: thumbSize),
            radius: 0,
            shadowOpacity: 0
        )
    }

    /// The page in its cell (`cell` in window coordinates): the page scaled as its thumbnail is, clipped
    /// to the cell.
    func cellPose(_ capture: PageCapture, cell: CGRect) -> Pose {
        let page = capture.pageFrame
        let visible = capture.visibleFrame
        let scale = Self.thumbScale(pageSize: page.size, thumb: cell.size)
        let local = CGRect(
            x: (visible.minX - page.minX) * scale, y: (visible.minY - page.minY) * scale,
            width: visible.width * scale, height: visible.height * scale
        )
        return Pose(
            container: convert(cell, from: nil),
            snapshot: local,
            thumb: CGRect(origin: .zero, size: cell.size),
            radius: Tokens.Radius.pageThumb,
            shadowOpacity: Float(Tokens.Shadows.thumb.color.alpha)
        )
    }

    /// `ThumbnailService.Frame.pageFrame`: the page scaled to fill the thumb, top-left aligned.
    private static func thumbScale(pageSize: CGSize, thumb: CGSize) -> CGFloat {
        max(thumb.width / max(pageSize.width, 1), thumb.height / max(pageSize.height, 1))
    }

    // MARK: Flight

    /// Springs from `from` to `to`. The snapshot rides on top of the thumbnail, which fills the cell
    /// where the snapshot doesn't (the page below the fold): opening it fades in over the second half,
    /// closing it is there from the first frame and the growing snapshot covers it. `completion` runs
    /// when the spring has settled.
    /// One flight: between two poses, with what the flyer shows.
    struct Plan {
        var from: Pose
        var to: Pose
        var opening: Bool
        var paper: UIColor
        var snapshot: UIView
        var thumb: UIImage?
    }

    func fly(_ plan: Plan, completion: @escaping @MainActor () -> Void) {
        layer.removeAllAnimations()
        [shadow, container.layer, thumb].forEach { $0.removeAllAnimations() }
        snapshot?.removeFromSuperview()
        snapshot = plan.snapshot
        plan.snapshot.frame = plan.from.snapshot
        container.addSubview(plan.snapshot)
        isFlying = true
        container.backgroundColor = plan.paper
        thumb.contents = plan.thumb?.cgImage
        setHidden(false)

        let spring = CASpringAnimation(perceptualDuration: FlightTiming.duration, bounce: FlightTiming.bounce)
        let settle = min(spring.settlingDuration, 0.6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard self.isFlying else { return }
                completion()
            }
        }
        animateGeometry(from: plan.from, to: plan.to, snapshot: plan.snapshot.layer, duration: settle)
        thumb.removeAnimation(forKey: "opacity")
        thumb.opacity = 1
        if plan.opening {
            // The thumbnail fills what the snapshot doesn't; it fades in under it over the second half.
            let fadeStart = FlightTiming.duration / 2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = FlightTiming.duration - fadeStart
            fade.beginTime = CACurrentMediaTime() + fadeStart
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            thumb.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    private func animateGeometry(from: Pose, to: Pose, snapshot: CALayer, duration: TimeInterval) {
        animateFrame(container.layer, from: from.container, to: to.container, duration: duration)
        animateFrame(shadow, from: from.container, to: to.container, duration: duration)
        animateFrame(snapshot, from: from.snapshot, to: to.snapshot, duration: duration)
        animateFrame(thumb, from: from.thumb, to: to.thumb, duration: duration)
        animate(container.layer, "cornerRadius", from: from.radius, to: to.radius, duration: duration)
        animate(shadow, "shadowOpacity", from: from.shadowOpacity, to: to.shadowOpacity, duration: duration)
        animate(
            shadow, "shadowPath",
            from: UIBezierPath(roundedRect: CGRect(origin: .zero, size: from.container.size), cornerRadius: from.radius).cgPath,
            to: UIBezierPath(roundedRect: CGRect(origin: .zero, size: to.container.size), cornerRadius: to.radius).cgPath,
            duration: duration
        )
    }

    /// The thumbnail arrived after take-off: it joins the flight where the fade already is.
    func setThumb(_ image: UIImage) {
        guard isFlying else { return }
        thumb.contents = image.cgImage
    }

    /// Takes the flyer down (after the grid cell or the canvas shows the same pixels).
    func clear() {
        isFlying = false
        [shadow, container.layer, thumb].forEach { $0.removeAllAnimations() }
        setHidden(true)
        snapshot?.removeFromSuperview()
        snapshot = nil
        thumb.contents = nil
    }

    private func setHidden(_ hidden: Bool) {
        shadow.isHidden = hidden
        container.isHidden = hidden
    }

    private func animateFrame(_ layer: CALayer, from: CGRect, to: CGRect, duration: TimeInterval) {
        animate(layer, "bounds", from: CGRect(origin: .zero, size: from.size), to: CGRect(origin: .zero, size: to.size), duration: duration)
        animate(layer, "position", from: CGPoint(x: from.midX, y: from.midY), to: CGPoint(x: to.midX, y: to.midY), duration: duration)
    }

    private func animate(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: TimeInterval) {
        let spring = CASpringAnimation(perceptualDuration: FlightTiming.duration, bounce: FlightTiming.bounce)
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = to
        spring.duration = duration
        layer.setValue(to, forKeyPath: keyPath)
        layer.add(spring, forKey: keyPath)
    }
}

/// Hosts a ``PageFlightView`` over the overview.
struct PageFlightHost: UIViewRepresentable {
    let view: PageFlightView

    func makeUIView(context _: Context) -> PageFlightView {
        view
    }

    func updateUIView(_: PageFlightView, context _: Context) {}
}
