import CoreGraphics
import Foundation

/// One committed ink stroke: raw samples plus pen, color and base width, and for PencilKit-captured
/// strokes the exact ``rendering`` (format v2).
///
/// Immutable geometry: ``samples``, ``width``, ``rendering`` and the derived ``bounds`` change only
/// through ``transformed(by:)`` (which yields a new value). Encodes without `bounds` (recomputed on decode).
public struct Stroke: Hashable, Sendable, Codable, Identifiable {
    /// Upper bound on any pen profile's width multiplier. `InkGeometry.PenProfile` must stay within it.
    public static let maxWidthScale: Float = 2
    /// Extra margin (pt) in ``bounds`` for the anti-aliasing fringe. Renderers keep geometry within
    /// ``bounds``; see ``bounds(of:width:rendering:)``.
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
    /// How PencilKit draws it (point sizes, opacity, ink, seed), parallel to ``samples``; `nil` when the
    /// stroke did not come from PencilKit (renderers then derive sizes from the pen profile).
    public private(set) var rendering: StrokeRendering?
    /// Conservative page-space bounds of everything this stroke can draw. `.null` if no samples.
    /// See ``bounds(of:width:rendering:)``.
    public private(set) var bounds: CGRect

    /// Creates a stroke and computes its bounds. A `rendering` whose point count differs from
    /// `samples.count` is dropped (it cannot describe these samples).
    public init(
        id: StrokeID = StrokeID(),
        tool: PenKind,
        color: InkColor,
        width: Float,
        samples: [Sample],
        rendering: StrokeRendering? = nil
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.width = width
        self.samples = samples
        self.rendering = rendering?.points.count == samples.count ? rendering : nil
        bounds = Self.bounds(of: samples, width: width, rendering: self.rendering)
    }

    /// Conservative bounds for `samples` drawn at base `width`: the samples' bounding box outset by
    /// `√2 × e / 2 + boundsMargin`, where `e` is `width × maxWidthScale` or the largest rendered point
    /// size, whichever is larger. The `√2` covers square cap quads at any angle.
    public static func bounds(of samples: [Sample], width: Float, rendering: StrokeRendering? = nil) -> CGRect {
        guard var minX = samples.first?.x, var minY = samples.first?.y else { return .null }
        var maxX = minX
        var maxY = minY
        for s in samples.dropFirst() {
            minX = min(minX, s.x)
            maxX = max(maxX, s.x)
            minY = min(minY, s.y)
            maxY = max(maxY, s.y)
        }
        let extent = max(max(width, 0) * maxWidthScale, rendering?.maximumPointSize ?? 0)
        let pad = CGFloat(extent / 2 * Float(2).squareRoot() + boundsMargin)
        return CGRect(
            x: CGFloat(minX) - pad,
            y: CGFloat(minY) - pad,
            width: CGFloat(maxX - minX) + 2 * pad,
            height: CGFloat(maxY - minY) + 2 * pad
        )
    }

    /// Returns a copy (same ID) with `transform` baked into the samples.
    ///
    /// Width and rendered point sizes scale by `√|det|` so a resized selection keeps its proportions;
    /// azimuth rotates with the transform's rotation component.
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
        if var rendering, scale != 1 {
            rendering.points = rendering.points.map { p in
                var scaled = p
                scaled.width *= scale
                scaled.height *= scale
                return scaled
            }
            copy.rendering = rendering
        }
        copy.bounds = Self.bounds(of: copy.samples, width: copy.width, rendering: copy.rendering)
        return copy
    }

    /// Returns a copy (same ID) with a different color.
    public func recolored(_ color: InkColor) -> Stroke {
        var copy = self
        copy.color = color
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, tool, color, width, samples, rendering
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(StrokeID.self, forKey: .id),
            tool: c.decode(PenKind.self, forKey: .tool),
            color: c.decode(InkColor.self, forKey: .color),
            width: c.decode(Float.self, forKey: .width),
            samples: c.decode([Sample].self, forKey: .samples),
            rendering: c.decodeIfPresent(StrokeRendering.self, forKey: .rendering)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tool, forKey: .tool)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        try c.encode(samples, forKey: .samples)
        try c.encodeIfPresent(rendering, forKey: .rendering)
    }
}
