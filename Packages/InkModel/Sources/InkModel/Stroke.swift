import CoreGraphics
import Foundation

/// One committed ink stroke: raw samples plus pen, color and base width.
///
/// Immutable geometry: ``samples``, ``width`` and the derived ``bounds`` change only through
/// ``transformed(by:)`` (which yields a new value). Encodes without `bounds` (recomputed on decode).
public struct Stroke: Hashable, Sendable, Codable, Identifiable {
    /// Upper bound on any pen profile's width multiplier. `InkGeometry.PenProfile` must stay within it.
    public static let maxWidthScale: Float = 2
    /// Extra margin (pt) in ``bounds`` for the anti-aliasing fringe. Renderers keep geometry within
    /// ``bounds``; see ``bounds(of:width:)``.
    public static let boundsMargin: Float = 3

    /// Stable identity (UUIDv7).
    public let id: StrokeID
    /// Pen family.
    public var tool: PenKind
    /// Ink color.
    public var color: InkColor
    /// Base width in points (before pen-profile modulation).
    public private(set) var width: Float
    /// Raw samples in page space.
    public private(set) var samples: [Sample]
    /// Conservative page-space bounds of everything this stroke can draw. `.null` if no samples.
    /// See ``bounds(of:width:)``.
    public private(set) var bounds: CGRect

    /// Creates a stroke and computes its bounds.
    public init(id: StrokeID = StrokeID(), tool: PenKind, color: InkColor, width: Float, samples: [Sample]) {
        self.id = id
        self.tool = tool
        self.color = color
        self.width = width
        self.samples = samples
        bounds = Self.bounds(of: samples, width: width)
    }

    /// Conservative bounds for `samples` drawn at base `width`: the samples' bounding box outset by
    /// `√2 × width × maxWidthScale / 2 + boundsMargin`. The `√2` covers square cap quads at any angle.
    public static func bounds(of samples: [Sample], width: Float) -> CGRect {
        guard var minX = samples.first?.x, var minY = samples.first?.y else { return .null }
        var maxX = minX
        var maxY = minY
        for s in samples.dropFirst() {
            minX = min(minX, s.x)
            maxX = max(maxX, s.x)
            minY = min(minY, s.y)
            maxY = max(maxY, s.y)
        }
        let pad = CGFloat(max(width, 0) * maxWidthScale / 2 * Float(2).squareRoot() + boundsMargin)
        return CGRect(
            x: CGFloat(minX) - pad,
            y: CGFloat(minY) - pad,
            width: CGFloat(maxX - minX) + 2 * pad,
            height: CGFloat(maxY - minY) + 2 * pad
        )
    }

    /// Returns a copy (same ID) with `transform` baked into the samples.
    ///
    /// Width scales by `√|det|` so a resized selection keeps its proportions; azimuth rotates with the
    /// transform's rotation component.
    public func transformed(by transform: CGAffineTransform) -> Stroke {
        let rotation = Float(atan2(transform.b, transform.a))
        let scale = Float(abs(transform.a * transform.d - transform.b * transform.c).squareRoot())
        var copy = self
        copy.samples = samples.map { s in
            let p = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)).applying(transform)
            var out = s
            out.x = Float(p.x)
            out.y = Float(p.y)
            out.azimuth = s.azimuth + rotation
            return out
        }
        copy.width = width * scale
        copy.bounds = Self.bounds(of: copy.samples, width: copy.width)
        return copy
    }

    /// Returns a copy (same ID) with a different color.
    public func recolored(_ color: InkColor) -> Stroke {
        var copy = self
        copy.color = color
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, tool, color, width, samples
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(StrokeID.self, forKey: .id),
            tool: c.decode(PenKind.self, forKey: .tool),
            color: c.decode(InkColor.self, forKey: .color),
            width: c.decode(Float.self, forKey: .width),
            samples: c.decode([Sample].self, forKey: .samples)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tool, forKey: .tool)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        try c.encode(samples, forKey: .samples)
    }
}
