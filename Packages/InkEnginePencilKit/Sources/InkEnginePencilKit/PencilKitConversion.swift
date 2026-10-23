import Foundation
import InkGeometry
import InkModel
import PencilKit
import UIKit

/// `Stroke` ↔ `PKStroke` and `PenKind` ↔ `PKInk.InkType`.
///
/// Each ``InkModel/Sample`` becomes one `PKStrokePoint` control point (and back), so sample count,
/// positions, timing, tilt and pressure round-trip. Point size is the pen profile's width at that
/// sample (pressure and tilt, no speed term), which PencilKit renders directly. PencilKit truncates
/// force to 3 decimals, so normalized pressure round-trips within ~2.5e-4.
public enum PencilKitConversion {
    /// `PKStrokePoint.force` is in `UITouch.force` units; Apple Pencil's `maximumPossibleForce` is 4.17.
    /// Our samples are normalized `0...1`. Verify on device that PencilKit-captured strokes match.
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

    /// Closest pen for a PencilKit ink.
    public static func penKind(for inkType: PKInk.InkType) -> PenKind {
        switch inkType {
        case .fountainPen: .fountain
        case .watercolor, .crayon: .brush
        case .marker: .highlighter
        default: .ballpoint
        }
    }

    /// An inking tool for `kind`, width clamped to the ink's valid range.
    public static func inkingTool(_ kind: PenKind, color: UIColor, width: Float) -> PKInkingTool {
        let type = inkType(for: kind)
        let range = type.validWidthRange
        return PKInkingTool(type, color: color, width: min(max(CGFloat(width), range.lowerBound), range.upperBound))
    }

    /// `stroke` as a PencilKit stroke drawn in `color` (already resolved for the paper theme).
    public static func pkStroke(from stroke: Stroke, color: UIColor) -> PKStroke {
        let profile = PenProfile(stroke.tool)
        let points = stroke.samples.map { s in
            let size = CGFloat(stroke.width * profile.widthScale(force: s.force, speed: 0, altitude: s.altitude))
            return PKStrokePoint(
                location: CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)),
                timeOffset: TimeInterval(s.t),
                size: CGSize(width: size, height: size),
                opacity: 1,
                force: CGFloat(s.force) * maximumForce,
                azimuth: CGFloat(s.azimuth),
                altitude: CGFloat(s.altitude)
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        return PKStroke(ink: PKInk(inkType(for: stroke.tool), color: color), path: path)
    }

    /// A model stroke from a PencilKit stroke. The stroke's `transform` is baked into the samples.
    /// - Parameters:
    ///   - tool: Pen; defaults to ``penKind(for:)`` of the ink.
    ///   - color: Ink color; defaults to the ink's color as `.custom`.
    ///   - width: Base width; defaults to the median of point sizes divided by the profile's width scale.
    public static func stroke(
        from pk: PKStroke,
        id: StrokeID = StrokeID(),
        tool: PenKind? = nil,
        color: InkColor? = nil,
        width: Float? = nil
    ) -> Stroke {
        let kind = tool ?? penKind(for: pk.ink.inkType)
        let profile = PenProfile(kind)
        let transform = pk.transform
        let rotation = Float(atan2(transform.b, transform.a))
        let scale = Float(abs(transform.a * transform.d - transform.b * transform.c).squareRoot())
        var samples: [Sample] = []
        var widths: [Float] = []
        samples.reserveCapacity(pk.path.count)
        for point in pk.path {
            let p = point.location.applying(transform)
            let s = Sample(
                x: Float(p.x),
                y: Float(p.y),
                force: Float(min(max(point.force / maximumForce, 0), 1)),
                altitude: Float(point.altitude),
                azimuth: Float(point.azimuth) + rotation,
                t: Float(point.timeOffset)
            )
            samples.append(s)
            widths.append(Float(point.size.width) / profile.widthScale(force: s.force, speed: 0, altitude: s.altitude))
        }
        let baseWidth = width ?? median(widths).map { $0 * scale } ?? 2
        return Stroke(id: id, tool: kind, color: color ?? .custom(RGBA8(pk.ink.color)), width: baseWidth, samples: samples)
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
