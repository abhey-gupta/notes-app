import Foundation
import InkGeometry
import InkModel
import PencilKit
import UIKit

/// `Stroke` ↔ `PKStroke` and `PenKind` ↔ `PKInk.InkType`.
///
/// Each ``InkModel/Sample`` becomes one `PKStrokePoint` control point (and back). A stroke's
/// ``InkModel/Stroke/rendering`` holds what PencilKit drew (ink, random seed, per-point size and opacity),
/// so `PKStroke → Stroke → PKStroke` gives the same points and renders the same pixels (#71). Strokes
/// without one (v1 files, fixtures) get ``InkGeometry`` 's ``InkModel/Stroke/derivedRendering``: point
/// size = base width × pen-profile scale, with a seed fixed by the stroke ID.
///
/// PencilKit keeps force to 3 decimals; normalized pressure maps back to the same value.
public enum PencilKitConversion {
    /// `PKStrokePoint.force` is in `UITouch.force` units; Apple Pencil's `maximumPossibleForce` is 4.17.
    /// Our samples are normalized `0...1`.
    public static let maximumForce: CGFloat = 25 / 6

    /// Closest PencilKit ink for a pen.
    public static func inkType(for kind: PenKind) -> PKInk.InkType {
        switch kind {
        case .fountain: .fountainPen
        case .ballpoint: .pen
        case .brush: .watercolor
        case .highlighter: .marker
        }
    }

    /// The ink a stroke's rendering names, or its pen's if this PencilKit doesn't know it.
    static func inkType(_ identifier: String, fallback kind: PenKind) -> PKInk.InkType {
        PKInk.InkType(rawValue: identifier) ?? inkType(for: kind)
    }

    /// Closest pen for a PencilKit ink.
    public static func penKind(for inkType: PKInk.InkType) -> PenKind {
        switch inkType {
        case .fountainPen: .fountain
        case .watercolor, .crayon: .brush
        case .marker: .highlighter
        default: .ballpoint
        }
    }

    // MARK: Width

    /// The tool width (pt) that maps to PencilKit's default width for the pen's ink: the middle of the
    /// toolbar's presets (`Tools.PenSettings.widths` 1.5/2.5/**4**/6/8, `HighlighterSettings.widths`
    /// 10/**16**/24).
    public static func referenceWidth(for kind: PenKind) -> Float {
        kind == .highlighter ? 16 : 4
    }

    /// PencilKit tool width for a toolbar width: the ink's `defaultWidth` scaled by
    /// `width / referenceWidth(for:)`, clamped to the ink's `validWidthRange`. So the middle preset
    /// draws like PencilKit's own default (Notes' pen) and the others step finer/bolder from it.
    public static func pencilKitWidth(for kind: PenKind, width: Float) -> CGFloat {
        let type = inkType(for: kind)
        let range = type.validWidthRange
        let scaled = type.defaultWidth * CGFloat(width / referenceWidth(for: kind))
        return min(max(scaled.isFinite ? scaled : type.defaultWidth, range.lowerBound), range.upperBound)
    }

    /// An inking tool for `kind` at toolbar `width` (see ``pencilKitWidth(for:width:)``).
    public static func inkingTool(_ kind: PenKind, color: UIColor, width: Float) -> PKInkingTool {
        PKInkingTool(inkType(for: kind), color: color, width: pencilKitWidth(for: kind, width: width))
    }

    // MARK: Strokes

    /// `stroke` as a PencilKit stroke drawn in `color` (already resolved for the paper theme), from its
    /// stored rendering (exact) or the derived one.
    public static func pkStroke(from stroke: Stroke, color: UIColor) -> PKStroke {
        let rendering = stroke.resolvedRendering
        var points: [PKStrokePoint] = []
        points.reserveCapacity(stroke.samples.count)
        for (s, r) in zip(stroke.samples, rendering.points) {
            let width = CGFloat(r.width)
            points.append(PKStrokePoint(
                location: CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)),
                timeOffset: TimeInterval(s.t),
                size: CGSize(width: width, height: Quantum.height(CGFloat(r.height), width: width)),
                opacity: CGFloat(r.opacity) + Quantum.opacity / 4,
                force: pencilKitForce(s.force),
                azimuth: CGFloat(s.azimuth) + Quantum.azimuth / 4,
                altitude: CGFloat(s.altitude) - Quantum.altitude / 4 // rounds up, unlike the others
            ))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        return PKStroke(
            ink: PKInk(inkType(rendering.ink, fallback: stroke.tool), color: color),
            path: path,
            transform: .identity,
            mask: nil,
            randomSeed: rendering.randomSeed
        )
    }

    /// A model stroke from a PencilKit stroke, keeping its ink, seed and per-point size and opacity in
    /// ``InkModel/Stroke/rendering``. The stroke's `transform` is baked into the samples (sizes scale by
    /// `√|det|`); identity for everything PencilKit draws here. A `mask` (PencilKit's bitmap eraser) is
    /// not kept: our eraser works on the model.
    /// - Parameters:
    ///   - tool: Pen; defaults to ``penKind(for:)`` of the ink.
    ///   - color: Ink color; defaults to the ink's color as `.custom`.
    ///   - width: Base width (pt, the toolbar width); defaults to the median point size.
    public static func stroke(
        from pk: PKStroke,
        id: StrokeID = StrokeID(),
        tool: PenKind? = nil,
        color: InkColor? = nil,
        width: Float? = nil
    ) -> Stroke {
        let kind = tool ?? penKind(for: pk.ink.inkType)
        let transform = pk.transform
        let rotation = Float(atan2(transform.b, transform.a))
        let scale = abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
        var samples: [Sample] = []
        var points: [PointRendering] = []
        samples.reserveCapacity(pk.path.count)
        points.reserveCapacity(pk.path.count)
        for point in pk.path {
            let p = point.location.applying(transform)
            samples.append(Sample(
                x: Float(p.x),
                y: Float(p.y),
                force: Float(min(max(point.force / maximumForce, 0), 1)),
                altitude: Float(point.altitude),
                azimuth: Float(point.azimuth) + rotation,
                t: Float(point.timeOffset)
            ))
            points.append(PointRendering(
                width: Float(point.size.width * scale),
                height: Float(point.size.height * scale),
                opacity: Float(point.opacity)
            ))
        }
        let rendering = StrokeRendering(ink: pk.ink.inkType.rawValue, randomSeed: pk.randomSeed, points: points)
        let baseWidth = width ?? median(points.map(\.width)) ?? 2
        return Stroke(
            id: id, tool: kind, color: color ?? .custom(RGBA8(pk.ink.color)), width: baseWidth, samples: samples, rendering: rendering
        )
    }

    /// Normalized pressure in PencilKit force units: the 0.001 step PencilKit keeps, aimed a quarter
    /// step in so it truncates back to the same value.
    static func pencilKitForce(_ force: Float) -> CGFloat {
        ((CGFloat(force) * maximumForce / Quantum.force).rounded() + 0.25) * Quantum.force
    }

    /// How PencilKit quantizes `PKStrokePoint` fields (measured on iOS 27): location, time and width are
    /// Float32; the rest snap to steps, truncating down (altitude: up). A value read back sits on a step
    /// edge, often a hair off it after the Float32 round trip (or even in PencilKit's own arithmetic), so
    /// writing it back as is can land one step off. Writing it a quarter step into the step (up, or down
    /// for altitude) lands in the same step, which is what makes `PKStroke → Stroke → PKStroke` exact.
    /// `LosslessRoundTripTests` fails if a PencilKit release changes this.
    enum Quantum {
        static let opacity: CGFloat = 1 / 65535
        static let altitude: CGFloat = .pi / 2 / 65535
        static let azimuth: CGFloat = 2 * .pi / 65535
        static let force: CGFloat = 0.001
        /// Height is stored as a multiple of width in this step.
        static let aspect: CGFloat = 0.001

        static func height(_ height: CGFloat, width: CGFloat) -> CGFloat {
            guard width > 0, height.isFinite, width.isFinite else { return height }
            return ((height / width / aspect).rounded() + 0.25) * aspect * width
        }
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}

public extension UIColor {
    /// sRGB color from straight-alpha 8-bit channels.
    convenience init(_ rgba: RGBA8) {
        self.init(
            red: CGFloat(rgba.r) / 255,
            green: CGFloat(rgba.g) / 255,
            blue: CGFloat(rgba.b) / 255,
            alpha: CGFloat(rgba.a) / 255
        )
    }
}

public extension RGBA8 {
    /// Nearest 8-bit sRGB value of `color` (extended-range components clamp).
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt8 {
            UInt8((min(max(v, 0), 1) * 255).rounded())
        }
        self.init(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
    }
}
