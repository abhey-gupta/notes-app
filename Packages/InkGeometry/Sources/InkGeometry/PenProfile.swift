import InkModel

/// How a stroke's ends are shaped.
public enum CapStyle: UInt8, Hashable, Sendable {
    /// Semicircular cap (pens).
    case round
    /// Flat cap at the end sample (highlighter chisel).
    case butt
}

/// Per-pen width function and render traits (ARCHITECTURE.md §3.3).
///
/// ``widthScale(force:speed:altitude:)`` multiplies the stroke's base width and always lies in
/// `minWidthScale...Stroke.maxWidthScale`, which keeps every outline inside ``InkModel/Stroke/bounds``.
public struct PenProfile: Hashable, Sendable {
    /// Lower clamp of ``widthScale(force:speed:altitude:)``.
    public static let minWidthScale: Float = 0.2

    /// Pen family.
    public let kind: PenKind
    /// End-cap shape.
    public let capStyle: CapStyle
    /// Ink opacity (highlighter is translucent).
    public let opacity: Float
    /// Drawn in the highlighter pass beneath all pen ink, with multiply blending.
    public let drawsBeneathInk: Bool
    /// Fraction of the radius over which coverage fades to zero at the edge (soft brush edge).
    /// `0` means a hard edge with ~1 px anti-aliasing. The fade lies inside the radius.
    public let edgeSoftness: Float

    /// Profile for `kind`.
    public init(_ kind: PenKind) {
        self.kind = kind
        capStyle = kind == .highlighter ? .butt : .round
        opacity = kind == .highlighter ? 0.55 : 1
        drawsBeneathInk = kind == .highlighter
        edgeSoftness = kind == .brush ? 0.35 : 0
    }

    /// Thick/thin: pressure widens, speed thins.
    public static let fountain = PenProfile(.fountain)
    /// Near-constant width with slight pressure response.
    public static let ballpoint = PenProfile(.ballpoint)
    /// Pressure and tilt widen; soft edge.
    public static let brush = PenProfile(.brush)
    /// Constant width, flat caps, 55 % alpha (the mock's `rgba(255,214,51,.55)`), beneath ink.
    public static let highlighter = PenProfile(.highlighter)

    /// Width multiplier for one sample.
    /// - Parameters:
    ///   - force: Normalized pressure `0...1` (clamped; non-finite → ``InkModel/Sample/neutralForce``).
    ///   - speed: Pen speed in pt/s.
    ///   - altitude: Pencil altitude in radians (`π/2` upright).
    public func widthScale(force: Float, speed: Float, altitude: Float) -> Float {
        let p = force.isFinite ? min(max(force, 0), 1) : Sample.neutralForce
        let v = speed.isFinite ? max(speed, 0) : 0
        let upright = altitude.isFinite ? min(max(altitude / (.pi / 2), 0), 1) : 1
        let scale: Float = switch kind {
        case .fountain:
            // 0.4 + p^0.75 (0.4...1.4), thinned up to 30 % at high speed.
            (0.4 + p.squareRoot() * p.squareRoot().squareRoot()) * (1 - 0.3 * v / (v + 500))
        case .ballpoint:
            0.9 + 0.2 * p
        case .brush:
            // Pressure 0.25...1.45, tilting widens up to 1.6×.
            (0.25 + 1.2 * p) * (1 + 0.6 * (1 - upright))
        case .highlighter:
            1
        }
        return min(max(scale, Self.minWidthScale), Stroke.maxWidthScale)
    }
}
