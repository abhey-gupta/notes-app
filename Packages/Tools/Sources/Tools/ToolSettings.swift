import Foundation
import InkModel

/// The editor tools (ARCHITECTURE.md §6), in toolbar order.
public enum Tool: String, CaseIterable, Hashable, Sendable, Codable {
    case pen, highlighter, eraser, lasso, laser

    /// Puts ink down (counts toward focus mode, takes a color).
    public var inks: Bool {
        self == .pen || self == .highlighter
    }
}

/// Where the toolbar docks (ARCHITECTURE.md §7). Left/right render vertically.
public enum ToolbarDock: String, CaseIterable, Hashable, Sendable, Codable {
    case top, bottom, left, right

    /// Left and right docks lay the toolbar out vertically.
    public var isVertical: Bool {
        self == .left || self == .right
    }
}

/// A pen or highlighter size in page millimetres (A4 is 210 mm wide), in 0.1 mm steps, plus three saved
/// sizes the options popover offers as one-tap chips (#168). Range checks belong to the owner, which
/// knows the family (``PenSettings/sizeRange(for:)``).
public struct InkSize: Hashable, Sendable, Codable {
    /// Slider and ± step.
    public static let step: Float = 0.1
    /// Page points per millimetre (PostScript points, as the A4 page size).
    public static let pointsPerMillimetre: Float = 72 / 25.4
    /// Saved-size chips.
    public static let savedCount = 3

    /// Current size (mm).
    public var millimetres: Float
    /// Saved sizes (mm), always ``savedCount`` long once normalized.
    public var saved: [Float]

    public init(_ millimetres: Float, saved: [Float]) {
        self.millimetres = millimetres
        self.saved = saved
    }

    /// Width on the page in points: what the stroke draws.
    public var points: Float {
        millimetres * Self.pointsPerMillimetre
    }

    /// Snapped to 0.1 mm and clamped to `range`; saved sizes likewise, padded from `fallback`.
    public func normalized(to range: ClosedRange<Float>, fallback: InkSize) -> InkSize {
        let saved = (0 ..< Self.savedCount).map { i in
            Self.snap(i < self.saved.count ? self.saved[i] : fallback.saved[i], to: range)
        }
        return InkSize(Self.snap(millimetres, to: range), saved: saved)
    }

    /// `value` rounded to the nearest 0.1 mm inside `range` (non-finite → lower bound).
    public static func snap(_ value: Float, to range: ClosedRange<Float>) -> Float {
        guard value.isFinite else { return range.lowerBound }
        let stepped = (value / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

/// Pen settings: family, a size per family, color, pressure.
public struct PenSettings: Hashable, Sendable, Codable {
    /// Families offered for the pen tool (the highlighter is its own tool).
    public static let kinds: [PenKind] = [.fountain, .ballpoint, .brush]

    /// Sizes (mm) a family offers. PencilKit's watercolor can't draw thinner than ~6 mm.
    public static func sizeRange(for kind: PenKind) -> ClosedRange<Float> {
        switch kind {
        case .fountain, .ballpoint: 0.1 ... 2
        case .brush: 6 ... 20
        case .highlighter: HighlighterSettings.sizeRange
        }
    }

    /// Fresh size for a family (a fine 0.5 mm ballpoint, #71 follow-up).
    public static func defaultSize(for kind: PenKind) -> InkSize {
        switch kind {
        case .fountain, .ballpoint: InkSize(0.5, saved: [0.3, 0.5, 1])
        case .brush: InkSize(8, saved: [6, 10, 15])
        case .highlighter: HighlighterSettings.defaultSize
        }
    }

    /// Pen family; never `.highlighter` (falls back to `.ballpoint`).
    public var kind: PenKind {
        didSet {
            if !Self.kinds.contains(kind) {
                kind = .ballpoint
            }
        }
    }

    /// Size per family, normalized; read and write through ``size``.
    public private(set) var sizes: [PenKind: InkSize]

    /// Ink color.
    public var color: InkColor
    /// Pressure modulates width.
    public var pressure: Bool

    /// The current family's size; writes snap to 0.1 mm inside ``sizeRange(for:)``.
    public var size: InkSize {
        get { sizes[kind] ?? Self.defaultSize(for: kind) }
        set { sizes[kind] = newValue.normalized(to: Self.sizeRange(for: kind), fallback: Self.defaultSize(for: kind)) }
    }

    /// Width on the page in points.
    public var width: Float {
        size.points
    }

    /// Creates pen settings (out-of-range values are normalized).
    public init(kind: PenKind = .ballpoint, sizes: [PenKind: InkSize] = [:], color: InkColor = .primary, pressure: Bool = true) {
        self.kind = Self.kinds.contains(kind) ? kind : .ballpoint
        self.sizes = Dictionary(uniqueKeysWithValues: Self.kinds.map { kind in
            let fallback = Self.defaultSize(for: kind)
            return (kind, (sizes[kind] ?? fallback).normalized(to: Self.sizeRange(for: kind), fallback: fallback))
        })
        self.color = color
        self.pressure = pressure
    }
}

/// Highlighter settings: size, color and nib.
public struct HighlighterSettings: Hashable, Sendable, Codable {
    /// Band widths (mm) offered.
    public static let sizeRange: ClosedRange<Float> = 2 ... 12
    /// Fresh size.
    public static let defaultSize = InkSize(5.5, saved: [3.5, 5.5, 8.5])
    /// Mock highlighter yellow (`#FFD633`); translucency comes from the pen profile.
    public static let yellow = InkColor.custom(RGBA8(r: 0xFF, g: 0xD6, b: 0x33))

    /// Size; writes snap to 0.1 mm inside ``sizeRange``.
    public var size: InkSize {
        didSet { size = size.normalized(to: Self.sizeRange, fallback: Self.defaultSize) }
    }

    /// Highlight color.
    public var color: InkColor
    /// Nib shape (#215).
    public var nib: HighlighterNib

    /// Band width in points.
    public var width: Float {
        size.points
    }

    /// Creates highlighter settings.
    public init(
        size: InkSize = HighlighterSettings.defaultSize, color: InkColor = HighlighterSettings.yellow, nib: HighlighterNib = .chisel
    ) {
        self.size = size.normalized(to: Self.sizeRange, fallback: Self.defaultSize)
        self.color = color
        self.nib = nib
    }
}

/// Eraser settings: whole-stroke or partial, a width step, and whether lifting after an erase goes back to
/// the previous tool.
public struct EraserSettings: Hashable, Sendable, Codable {
    /// Whole strokes (`PageEdit.remove`) or split where touched (`PageEdit.replace`).
    public enum Mode: String, CaseIterable, Hashable, Sendable, Codable {
        case stroke, partial
    }

    /// Eraser diameters in points, by ``widthIndex``.
    public static let widths: [Float] = [8, 16, 32]

    /// Erase mode.
    public var mode: Mode
    /// Index into ``widths``, clamped.
    public var widthIndex: Int {
        didSet { widthIndex = widthIndex.clamped(to: Self.widths.indices) }
    }

    /// Lifting after an eraser stroke switches back to the previous tool (#156).
    public var autoDeselect: Bool

    /// Diameter in points.
    public var width: Float {
        Self.widths[widthIndex]
    }

    /// Creates eraser settings.
    public init(mode: Mode = .stroke, widthIndex: Int = 1, autoDeselect: Bool = true) {
        self.mode = mode
        self.widthIndex = widthIndex.clamped(to: Self.widths.indices)
        self.autoDeselect = autoDeselect
    }

    private enum CodingKeys: String, CodingKey {
        case mode, widthIndex, autoDeselect
    }

    /// `autoDeselect` is optional so settings saved before #156 keep their mode and size.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(Mode.self, forKey: .mode),
            widthIndex: container.decode(Int.self, forKey: .widthIndex),
            autoDeselect: container.decodeIfPresent(Bool.self, forKey: .autoDeselect) ?? true
        )
    }
}

/// Laser pointer settings (#159): a fading trail behind the tip, or just a dot under it. Red, fixed width.
public struct LaserSettings: Hashable, Sendable, Codable {
    /// Trail or dot.
    public enum Mode: String, CaseIterable, Hashable, Sendable, Codable {
        case trail, dot
    }

    /// Trail or dot.
    public var mode: Mode

    /// Creates laser settings.
    public init(mode: Mode = .trail) {
        self.mode = mode
    }
}

/// Everything ``ToolState`` persists, as one Codable blob.
///
/// Decoding is lenient: missing or invalid fields fall back to the defaults passed to ``ToolState``, so
/// adding a field never wipes a user's settings.
public struct ToolSettings: Hashable, Sendable, Codable {
    /// Most quick colors a palette holds (#125); it always holds at least one.
    public static let maxQuickColors = 5

    /// Current tool.
    public var tool: Tool
    /// Pen settings.
    public var pen: PenSettings
    /// Highlighter settings.
    public var highlighter: HighlighterSettings
    /// Eraser settings.
    public var eraser: EraserSettings
    /// Laser pointer settings.
    public var laser: LaserSettings
    /// Pen quick colors, 1...``maxQuickColors``.
    public var quickColors: [InkColor] {
        didSet { quickColors = Self.normalized(quickColors, defaults: Self.defaultQuickColors) }
    }

    /// Highlighter quick colors, 1...``maxQuickColors`` (#125: each inking tool has its own).
    public var highlighterColors: [InkColor] {
        didSet { highlighterColors = Self.normalized(highlighterColors, defaults: [HighlighterSettings.yellow]) }
    }

    /// Toolbar dock.
    public var dock: ToolbarDock

    /// Creates settings. Palettes keep their first ``maxQuickColors``; an empty one takes the defaults.
    public init(
        tool: Tool = .pen,
        pen: PenSettings = PenSettings(),
        highlighter: HighlighterSettings = HighlighterSettings(),
        eraser: EraserSettings = EraserSettings(),
        laser: LaserSettings = LaserSettings(),
        quickColors: [InkColor] = [.semantic(.primary), .semantic(.blue), .semantic(.red)],
        highlighterColors: [InkColor] = [HighlighterSettings.yellow],
        dock: ToolbarDock = .top
    ) {
        self.tool = tool
        // Re-run the normalizing inits: synthesized decoding skips them.
        self.pen = PenSettings(kind: pen.kind, sizes: pen.sizes, color: pen.color, pressure: pen.pressure)
        self.highlighter = HighlighterSettings(size: highlighter.size, color: highlighter.color, nib: highlighter.nib)
        self.eraser = EraserSettings(mode: eraser.mode, widthIndex: eraser.widthIndex, autoDeselect: eraser.autoDeselect)
        self.laser = laser
        self.quickColors = Self.normalized(quickColors, defaults: Self.defaultQuickColors)
        self.highlighterColors = Self.normalized(highlighterColors, defaults: [HighlighterSettings.yellow])
        self.dock = dock
    }

    private static func normalized(_ colors: [InkColor], defaults: [InkColor]) -> [InkColor] {
        colors.isEmpty ? defaults : Array(colors.prefix(maxQuickColors))
    }

    private static let defaultQuickColors: [InkColor] = [.semantic(.primary), .semantic(.blue), .semantic(.red)]
}

extension ToolSettings {
    /// Decodes `data`, taking each missing or unreadable field from `defaults`.
    static func decode(_ data: Data, defaults: ToolSettings) -> ToolSettings {
        guard let stored = try? JSONDecoder().decode(StoredToolSettings.self, from: data) else { return defaults }
        return ToolSettings(
            tool: stored.tool ?? defaults.tool,
            pen: stored.pen ?? defaults.pen,
            highlighter: stored.highlighter ?? defaults.highlighter,
            eraser: stored.eraser ?? defaults.eraser,
            laser: stored.laser ?? defaults.laser,
            quickColors: stored.quickColors ?? defaults.quickColors,
            highlighterColors: stored.highlighterColors ?? defaults.highlighterColors,
            dock: stored.dock ?? defaults.dock
        )
    }
}

/// Every field optional and individually lenient, so one bad field doesn't discard the rest.
private struct StoredToolSettings: Decodable {
    var tool: Tool?
    var pen: PenSettings?
    var highlighter: HighlighterSettings?
    var eraser: EraserSettings?
    var laser: LaserSettings?
    var quickColors: [InkColor]?
    var highlighterColors: [InkColor]?
    var dock: ToolbarDock?

    private enum CodingKeys: String, CodingKey {
        case tool, pen, highlighter, eraser, laser, quickColors, highlighterColors, dock
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            try? container.decodeIfPresent(T.self, forKey: key)
        }
        tool = field(.tool)
        pen = field(.pen)
        highlighter = field(.highlighter)
        eraser = field(.eraser)
        laser = field(.laser)
        quickColors = field(.quickColors)
        highlighterColors = field(.highlighterColors)
        dock = field(.dock)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
