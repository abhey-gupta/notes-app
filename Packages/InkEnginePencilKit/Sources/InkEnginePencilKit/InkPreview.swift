import InkGeometry
import InkModel
import PencilKit
import UIKit

/// The tool popover's sample stroke (#27): a synthetic handwriting squiggle drawn by PencilKit with the ink,
/// width mapping (``PencilKitConversion/pencilKitWidth(for:width:)``) and pen profile real strokes get, so it
/// shows what the next stroke will look like.
///
/// Ink bolder than the preview can hold (brush, highlighter) is drawn true-size in a larger space and scaled
/// down to fit (``fit(_:in:)``), so its texture and shape still match the canvas.
public enum InkPreview {
    /// What to draw.
    public struct Spec: Hashable, Sendable {
        /// Pen family (`.highlighter` for the highlighter).
        public var kind: PenKind
        /// Toolbar width (pt), as in `ToolConfiguration.width`.
        public var width: Float
        /// Ink color, already resolved for the paper.
        public var color: RGBA8
        /// Pressure varies the width along the stroke; off draws every point at neutral force.
        public var pressure: Bool

        public init(kind: PenKind, width: Float, color: RGBA8, pressure: Bool = true) {
            self.kind = kind
            self.width = width
            self.color = color
            self.pressure = pressure
        }
    }

    /// Control points in the stroke (PencilKit splines between them).
    static let pointCount = 96
    /// The thickest point may take at most this fraction of the preview height.
    static let maxInkFraction: CGFloat = 0.42
    /// Inset from the preview's edges, in preview points.
    static let margin: CGFloat = 10
    /// Writing speed for time offsets (pt/s).
    static let speed: CGFloat = 380
    /// Squiggle cycles across the preview.
    static let cycles: CGFloat = 1.9
    /// Start phase: begins below the centre line, heading up (mock §03).
    static let phase: CGFloat = 0.7 * .pi
    /// A right-handed grip: Pencil tilted 60°, barrel toward the lower right.
    static let altitude: CGFloat = .pi / 3
    static let azimuth: CGFloat = .pi / 4
    /// Live watercolor strokes carry this wash scale (#71).
    static let watercolorSecondaryScale: CGFloat = 0.83
    /// Fixed so textured inks render the same grain every time.
    static let randomSeed: UInt32 = 0x5EED_1DEA
    private static let renderGroup = UUID(uuidString: "6F1A2C1E-27B0-4E7E-9C3A-7A5E1DEA0027")
    private static let traits = UITraitCollection(userInterfaceStyle: .light)

    /// Scale (≤ 1) the preview is drawn at so its thickest point fits `size`.
    public static func fit(_ spec: Spec, in size: CGSize) -> CGFloat {
        let thickest = pointWidths(spec).max() ?? 0
        guard thickest > 0, size.height > 0 else { return 1 }
        return min(1, size.height * maxInkFraction / thickest)
    }

    /// The preview stroke, laid out in a space `size / fit(spec, in: size)` large.
    public static func stroke(_ spec: Spec, in size: CGSize) -> PKStroke {
        let fit = fit(spec, in: size)
        let space = CGSize(width: size.width / fit, height: size.height / fit)
        let forces = Self.forces(spec)
        let widths = pointWidths(spec)
        let thickest = widths.max() ?? 0
        let inset = margin / fit + thickest / 2
        let room = max(0, (space.height - thickest) / 2 - margin / fit)
        let amplitude = min(room, space.height * (spec.kind == .highlighter ? 0.05 : 0.26))
        let (x0, x1) = (inset, max(inset, space.width - inset))
        var points: [PKStrokePoint] = []
        points.reserveCapacity(widths.count)
        var time: TimeInterval = 0
        var last: CGPoint?
        for (i, width) in widths.enumerated() {
            let t = CGFloat(i) / CGFloat(widths.count - 1)
            let envelope = 1 - 0.3 * t
            let location = CGPoint(
                x: x0 + (x1 - x0) * t,
                y: space.height / 2 + amplitude * envelope * sin(2 * .pi * cycles * t + phase)
            )
            if let last {
                time += TimeInterval(hypot(location.x - last.x, location.y - last.y) * fit / speed)
            }
            last = location
            points.append(point(location, time: time, width: width, force: forces[i], kind: spec.kind))
        }
        let ink = PKInk(PencilKitConversion.inkType(for: spec.kind), color: UIColor(spec.color))
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        var stroke = PKStroke(ink: ink, path: path, transform: .identity, mask: nil, randomSeed: randomSeed)
        if #available(iOS 27, *), spec.kind == .brush {
            stroke.renderGroupID = renderGroup
        }
        return stroke
    }

    /// ``stroke(_:in:)`` rendered `size` large (points) at `scale` on a clear background, with light traits
    /// like the canvas (colors are already resolved for the paper).
    public static func image(_ spec: Spec, size: CGSize, scale: CGFloat) -> UIImage {
        let fit = fit(spec, in: size)
        let drawing = PKDrawing(strokes: [stroke(spec, in: size)])
        let rect = CGRect(x: 0, y: 0, width: size.width / fit, height: size.height / fit)
        var image = UIImage()
        traits.performAsCurrent {
            image = drawing.image(from: rect, scale: scale * fit)
        }
        return image
    }

    // MARK: Profile

    /// Normalized pressure along the stroke: lands light, presses harder on downstrokes, lifts off.
    static func forces(_ spec: Spec) -> [Float] {
        (0 ..< pointCount).map { i in
            guard spec.pressure else { return Sample.neutralForce }
            let t = CGFloat(i) / CGFloat(pointCount - 1)
            let envelope = smoothstep(0, 0.12, t) * (1 - smoothstep(0.84, 1, t))
            let stroke = 0.6 + 0.2 * cos(2 * .pi * cycles * t + phase)
            return Float(0.1 + (stroke - 0.1) * envelope)
        }
    }

    /// Point widths (pt): the PencilKit tool width at neutral force, shaped by the pen profile.
    static func pointWidths(_ spec: Spec) -> [CGFloat] {
        let base = PencilKitConversion.pencilKitWidth(for: spec.kind, width: spec.width)
        let profile = PenProfile(spec.kind)
        let neutral = profile.widthScale(force: Sample.neutralForce, speed: 0, altitude: Float(altitude))
        return forces(spec).map { force in
            base * CGFloat(profile.widthScale(force: force, speed: 0, altitude: Float(altitude)) / neutral)
        }
    }

    private static func point(_ location: CGPoint, time: TimeInterval, width: CGFloat, force: Float, kind: PenKind) -> PKStrokePoint {
        PKStrokePoint(
            location: location,
            timeOffset: time,
            size: CGSize(width: width, height: width),
            opacity: 1,
            force: CGFloat(force) * PencilKitConversion.maximumForce,
            azimuth: azimuth,
            altitude: altitude,
            secondaryScale: kind == .brush ? watercolorSecondaryScale : 1
        )
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
