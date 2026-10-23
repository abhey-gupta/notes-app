/// Exactly how PencilKit draws a stroke (format v2, #71): its ink, random seed and, parallel to
/// ``Stroke/samples``, each control point's rendered size and opacity.
///
/// Strokes captured by PencilKit carry this so they render identically after reload or when their page
/// stops being active; recomputing sizes from a ``PenKind`` profile does not reproduce PencilKit's
/// weight. Strokes from elsewhere (v1 files, fixtures, other engines) have none and renderers derive
/// sizes from the pen profile. Values are stored as PencilKit reports them (it quantizes internally), so
/// feeding them back gives the same `PKStrokePoint`s.
public struct StrokeRendering: Hashable, Sendable, Codable {
    /// PencilKit ink identifier (`PKInk.InkType.rawValue`, e.g. ``Ink/pen``), 1...255 UTF-8 bytes.
    public var ink: String
    /// `PKStroke.randomSeed` (texture of pencil, crayon and watercolor inks).
    public var randomSeed: UInt32
    /// One per sample.
    public var points: [PointRendering]

    /// Creates rendering data. `points` must be parallel to the stroke's samples.
    public init(ink: String, randomSeed: UInt32, points: [PointRendering]) {
        self.ink = ink
        self.randomSeed = randomSeed
        self.points = points
    }

    /// Largest point extent (width or height), 0 if none.
    public var maximumPointSize: Float {
        points.reduce(0) { max($0, $1.width, $1.height) }
    }

    /// PencilKit ink identifiers (`PKInk.InkType` raw values), spelled out so headless packages
    /// (fixtures, migration) can name them without importing PencilKit.
    public enum Ink {
        public static let pen = "com.apple.ink.pen"
        public static let pencil = "com.apple.ink.pencil"
        public static let marker = "com.apple.ink.marker"
        public static let monoline = "com.apple.ink.monoline"
        public static let fountainPen = "com.apple.ink.fountainpen"
        public static let watercolor = "com.apple.ink.watercolor"
        public static let crayon = "com.apple.ink.crayon"

        /// The ink a pen draws with (ARCHITECTURE.md §3).
        public static func `for`(_ kind: PenKind) -> String {
            switch kind {
            case .fountain: fountainPen
            case .ballpoint: pen
            case .brush: watercolor
            case .highlighter: marker
            }
        }
    }
}

/// One control point's rendered size (`PKStrokePoint.size`, page points) and opacity.
public struct PointRendering: Hashable, Sendable, Codable, BitwiseCopyable {
    public var width: Float
    public var height: Float
    public var opacity: Float

    public init(width: Float, height: Float, opacity: Float = 1) {
        self.width = width
        self.height = height
        self.opacity = opacity
    }
}
