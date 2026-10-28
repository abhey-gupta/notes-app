import InkEngine
import InkModel
import UIKit

/// The laser pointer (#159) draws through the shared `InkInputView` and commits nothing: a glowing red dot
/// under the tip and, in trail mode, the ``LaserTrail`` behind it. Everything stays bright while the Pencil
/// touches and fades on lift (Core Animation, no display link); touching again mid-fade brings it back.
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
    /// Saturated laser red.
    static let color = UIColor(red: 1, green: 0.08, blue: 0.06, alpha: 1)
    /// Dot-only fade on lift (the trail takes ``LaserTrail/fadeDuration``).
    static let dotFade: CFTimeInterval = 0.15
    /// On-screen trail line widths (pt) and opacities, outer glow first.
    static let trailStrokes: [(CGFloat, Float)] = [(26, 0.14), (12, 0.45), (4.5, 1)]
    /// On-screen tip diameters (pt) and opacities, outer glow first.
    static let tipCircles: [(CGFloat, Float)] = [(34, 0.16), (18, 0.45), (9, 1)]

    /// Container: its opacity is the fade.
    let layer = CALayer()
    private(set) var trail = LaserTrail()
    /// Draw the trail (off: dot only).
    var trails = true
    /// Viewport zoom when the stroke was drawn (widths are divided by it).
    var zoom: CGFloat = 1

    private let lines = LaserPointer.trailStrokes.map { _ in CAShapeLayer() }
    /// Tip circles, core last.
    let tip = LaserPointer.tipCircles.map { _ in CAShapeLayer() }
    /// Committed samples of the current stroke already in the trail.
    private var followed = 0

    init() {
        for (line, (_, alpha)) in zip(lines, Self.trailStrokes) {
            line.fillColor = nil
            line.strokeColor = Self.color.withAlphaComponent(CGFloat(alpha)).cgColor
            line.lineCap = .round
            line.lineJoin = .round
            layer.addSublayer(line)
        }
        for (circle, (_, alpha)) in zip(tip, Self.tipCircles) {
            circle.fillColor = Self.color.withAlphaComponent(CGFloat(alpha)).cgColor
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
            fade(over: LaserTrail.fadeDuration)
        }
    }

    /// Tool switched away: everything goes at once.
    func clear() {
        trail.removeAll()
        layer.removeAnimation(forKey: "fade")
        layer.opacity = 0
    }

    private func fade(over duration: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
    }

    private func placeTip(at center: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (circle, (diameter, _)) in zip(tip, Self.tipCircles) {
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
        for (line, (width, _)) in zip(lines, Self.trailStrokes) {
            line.path = path
            line.lineWidth = width / zoom
        }
    }
}
