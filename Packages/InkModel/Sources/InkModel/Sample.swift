/// One raw Pencil sample in page space. 24 bytes, trivially copyable; the hot path.
///
/// Strokes persist raw samples (not outlines) so better tessellation later re-renders old notes better.
public struct Sample: Hashable, Sendable, Codable, BitwiseCopyable {
    /// Page-space x in points.
    public var x: Float
    /// Page-space y in points.
    public var y: Float
    /// Normalized pressure in `0...1` (`UITouch.force / maximumPossibleForce`).
    /// Inputs without pressure (finger, pressure toggle off) should use ``neutralForce``.
    public var force: Float
    /// Pencil altitude in radians: `0` = parallel to the screen, `π/2` = perpendicular.
    public var altitude: Float
    /// Pencil azimuth in radians, page space.
    public var azimuth: Float
    /// Seconds since the stroke's first sample.
    public var t: Float

    /// Pressure to record when the input device reports none.
    public static let neutralForce: Float = 0.5
    /// Altitude of a perpendicular pencil (no tilt).
    public static let perpendicularAltitude: Float = .pi / 2

    /// Creates a sample. Defaults describe an upright pencil at neutral pressure.
    public init(
        x: Float,
        y: Float,
        force: Float = Sample.neutralForce,
        altitude: Float = Sample.perpendicularAltitude,
        azimuth: Float = 0,
        t: Float = 0
    ) {
        self.x = x
        self.y = y
        self.force = force
        self.altitude = altitude
        self.azimuth = azimuth
        self.t = t
    }
}
