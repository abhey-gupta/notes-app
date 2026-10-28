import InkEngine
import InkModel
import UIKit

/// The laser pointer (#159) draws through the shared `InkInputView` and commits nothing: a red glowing dot
/// under the tip and, in trail mode, a ``LaserTrail`` behind it that fades as it ages. Drawn in content
/// space on the selection view, so it zooms with the page; widths are divided by zoom to stay constant on
/// screen. A display link runs only while something is visible.
extension PencilKitInkEngine {
    /// The current tool is the laser.
    var usesLaser: Bool {
        if case .laser = tool.tool {
            true
        } else {
            false
        }
    }

    func setUpLaser() {
        selection.view.layer.addSublayer(laser.layer)
    }

    func drawLaser(_ event: InkInputTracker.Event) {
        guard case let .laser(trail) = tool.tool else { return }
        laser.trails = trail
        laser.zoom = max(viewport.zoomScale, 0.01)
        switch event {
        case let .began(stroke):
            laser.begin()
            laser.follow(stroke)
        case let .updated(stroke):
            laser.follow(stroke)
        case .ended, .cancelled:
            laser.lift()
        }
    }
}

/// Layers and timing of the laser pointer.
@MainActor
final class LaserPointer: NSObject {
    /// Laser red (`#FF3B30`).
    static let color = UIColor(red: 1, green: 0x3B / 255, blue: 0x30 / 255, alpha: 1)
    /// Tip fade on lift.
    static let tipFade: CFTimeInterval = 0.15
    /// On-screen widths (pt): trail core and glow, tip core and glow diameters.
    static let coreWidth: CGFloat = 3
    static let glowWidth: CGFloat = 9
    static let tipDiameter: CGFloat = 7
    static let tipGlowDiameter: CGFloat = 18

    let layer = CALayer()
    /// Trail in content space.
    private(set) var trail = LaserTrail()
    /// Draw the trail (off: dot only).
    var trails = true
    /// Viewport zoom when the stroke was drawn (widths are divided by it).
    var zoom: CGFloat = 1

    private let glows = (0 ..< LaserTrail.bands).map { _ in CAShapeLayer() }
    private let cores = (0 ..< LaserTrail.bands).map { _ in CAShapeLayer() }
    let tipGlow = CAShapeLayer()
    let tip = CAShapeLayer()
    private var link: CADisplayLink?
    /// Committed samples already added to the trail.
    private var followed = 0

    /// Something is fading or following the tip (the display link is running).
    var isAnimating: Bool {
        link != nil
    }

    override init() {
        super.init()
        layer.actions = ["sublayers": NSNull()]
        for (glow, core) in zip(glows, cores) {
            for (shape, width, alpha) in [(glow, Self.glowWidth, 0.3), (core, Self.coreWidth, 1)] {
                shape.fillColor = nil
                shape.strokeColor = Self.color.withAlphaComponent(alpha).cgColor
                shape.lineWidth = width
                shape.lineCap = .round
                shape.lineJoin = .round
                layer.addSublayer(shape)
            }
        }
        tipGlow.fillColor = Self.color.withAlphaComponent(0.35).cgColor
        tip.fillColor = UIColor.white.cgColor
        tip.strokeColor = Self.color.cgColor
        layer.addSublayer(tipGlow)
        layer.addSublayer(tip)
        layer.opacity = 0
    }

    /// Pen down: the previous trail (still fading) gives way to the new one.
    func begin() {
        trail.removeAll()
        followed = 0
        tip.removeAnimation(forKey: "fade")
        tipGlow.removeAnimation(forKey: "fade")
        tip.opacity = 1
        tipGlow.opacity = 1
        layer.opacity = 1
        startLink()
    }

    /// New samples: the trail takes the committed ones at their touch times; the tip sits on the newest
    /// sample, predicted ones included.
    func follow(_ stroke: LiveStroke) {
        let pageToContent = stroke.viewToPage.inverted()
        func content(_ sample: Sample) -> CGPoint {
            CGPoint(x: CGFloat(sample.x), y: CGFloat(sample.y)).applying(pageToContent)
        }
        if trails, stroke.samples.count > followed {
            for sample in stroke.samples[followed...] {
                trail.append(content(sample), at: stroke.startTimestamp + TimeInterval(sample.t))
            }
        }
        followed = stroke.samples.count
        guard let last = stroke.displaySamples.last else { return }
        placeTip(at: content(last))
        redraw(now: CACurrentMediaTime())
    }

    /// Lift: the tip fades now, the trail ages out on its own.
    func lift() {
        for shape in [tip, tipGlow] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = Self.tipFade
            shape.opacity = 0
            shape.add(fade, forKey: "fade")
        }
        if trail.isEmpty {
            stopLink()
        }
    }

    /// Tool switched away: everything goes at once.
    func clear() {
        trail.removeAll()
        stopLink()
        layer.opacity = 0
    }

    private func placeTip(at center: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        func circle(_ diameter: CGFloat) -> CGPath {
            let d = diameter / zoom
            return CGPath(ellipseIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d), transform: nil)
        }
        tip.path = circle(Self.tipDiameter)
        tip.lineWidth = 1.5 / zoom
        tipGlow.path = circle(Self.tipGlowDiameter)
    }

    private func redraw(now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        trail.prune(now: now)
        let bands = trail.bands(now: now)
        for index in 0 ..< LaserTrail.bands {
            let band = index < bands.count ? bands[index] : nil
            let path = band.map { band -> CGPath in
                let path = CGMutablePath()
                path.addLines(between: band.points)
                return path
            }
            for (shape, width) in [(glows[index], Self.glowWidth), (cores[index], Self.coreWidth)] {
                shape.path = path
                shape.opacity = band?.opacity ?? 0
                shape.lineWidth = width / zoom
            }
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        redraw(now: CACurrentMediaTime())
        if trail.isEmpty, tip.opacity == 0 {
            stopLink()
        }
    }
}
