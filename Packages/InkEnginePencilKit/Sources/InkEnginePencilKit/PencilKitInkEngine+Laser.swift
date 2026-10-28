import InkEngine
import InkModel
import UIKit

/// The laser pointer (#159) draws through the shared `InkInputView` and commits nothing: a glowing red dot
/// under the tip and, in trail mode, the ``LaserTrail`` behind it. Everything stays bright while the Pencil
/// touches and fades shortly after lift (Core Animation, no display link); touching again mid-fade brings it back.
/// Drawn in content space on the selection view, so it zooms with the page; widths are divided by zoom to
/// stay constant on screen.
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
final class LaserPointer {
    /// Laser red.
    static let color = UIColor(red: 1, green: 0.1, blue: 0.08, alpha: 1)
    /// Dot-only fade on lift (the trail takes ``LaserTrail/fadeDuration``).
    static let dotFade: CFTimeInterval = 0.15
    /// Neon look, outer first: soft red glow, red rim, thin white core that makes it read bright.
    static let looks: [UIColor] = [color.withAlphaComponent(0.22), color, .white]
    /// On-screen trail line widths (pt), per ``looks``.
    static let trailWidths: [CGFloat] = [11, 5, 1.8]
    /// On-screen tip diameters (pt), per ``looks``.
    static let tipDiameters: [CGFloat] = [16, 8, 3.6]

    /// Container: its opacity is the fade.
    let layer = CALayer()
    private(set) var trail = LaserTrail()
    /// Draw the trail (off: dot only).
    var trails = true
    /// Viewport zoom when the stroke was drawn (widths are divided by it).
    var zoom: CGFloat = 1

    private let lines = LaserPointer.looks.map { _ in CAShapeLayer() }
    /// Tip circles, core last.
    let tip = LaserPointer.looks.map { _ in CAShapeLayer() }
    /// Committed samples of the current stroke already in the trail.
    private var followed = 0

    init() {
        for (line, look) in zip(lines, Self.looks) {
            line.fillColor = nil
            line.strokeColor = look.cgColor
            line.lineCap = .round
            line.lineJoin = .round
            layer.addSublayer(line)
        }
        for (circle, look) in zip(tip, Self.looks) {
            circle.fillColor = look.cgColor
            layer.addSublayer(circle)
        }
        layer.opacity = 0
    }

    /// Pen down: full brightness at once; a trail still fading stays and the new stroke adds to it.
    func begin() {
        trail.begin(at: CACurrentMediaTime())
        if !trails {
            trail.removeAll()
        }
        followed = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade")
        layer.opacity = 1
        for circle in tip {
            circle.isHidden = false
        }
        CATransaction.commit()
        redrawTrail()
    }

    /// New samples: the trail takes the committed ones; the tip sits on the newest sample, predicted ones
    /// included.
    func follow(_ stroke: LiveStroke) {
        let pageToContent = stroke.viewToPage.inverted()
        func content(_ sample: Sample) -> CGPoint {
            CGPoint(x: CGFloat(sample.x), y: CGFloat(sample.y)).applying(pageToContent)
        }
        if trails, stroke.samples.count > followed {
            for sample in stroke.samples[followed...] {
                trail.append(content(sample))
            }
            redrawTrail()
        }
        followed = stroke.samples.count
        guard let last = stroke.displaySamples.last else { return }
        placeTip(at: content(last))
    }

    /// Lift: a lone dot fades quickly; with a trail the tip goes and the trail fades out.
    func lift() {
        trail.lift(at: CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if trail.isEmpty {
            fade(over: Self.dotFade)
        } else {
            for circle in tip {
                circle.isHidden = true
            }
            fade(over: LaserTrail.fadeDuration, after: LaserTrail.hold)
        }
    }

    /// Tool switched away: everything goes at once.
    func clear() {
        trail.removeAll()
        layer.removeAnimation(forKey: "fade")
        layer.opacity = 0
    }

    /// Fully bright for `hold`, then to 0 over `duration`.
    private func fade(over duration: CFTimeInterval, after hold: CFTimeInterval = 0) {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: hold / (hold + duration)), 1]
        fade.duration = hold + duration
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
    }

    private func placeTip(at center: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (circle, diameter) in zip(tip, Self.tipDiameters) {
            let d = diameter / zoom
            circle.path = CGPath(ellipseIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d), transform: nil)
        }
    }

    private func redrawTrail() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = CGMutablePath()
        for stroke in trail.strokes where !stroke.isEmpty {
            path.addLines(between: stroke)
        }
        for (line, width) in zip(lines, Self.trailWidths) {
            line.path = path
            line.lineWidth = width / zoom
        }
    }
}
