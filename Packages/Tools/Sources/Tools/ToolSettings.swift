import Foundation
import InkModel

/// The four editor tools (ARCHITECTURE.md §6).
public enum Tool: String, CaseIterable, Hashable, Sendable, Codable {
    case pen, highlighter, eraser, lasso

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

/// Pen settings: family, width step, color, pressure.
public struct PenSettings: Hashable, Sendable, Codable {
    /// Pen widths in points, by ``widthIndex`` (mock units 3/5/8/11/15).
    public static let widths: [Float] = [1.5, 2.5, 4, 6, 8]
    /// Families offered for the pen tool (the highlighter is its own tool).
    public static let kinds: [PenKind] = [.fountain, .ballpoint, .brush]

    /// Pen family; never `.highlighter`.
    public var kind: PenKind {
        didSet {
            if !Self.kinds.contains(kind) {
                kind = .fountain
            }
        }
    }

    /// Index into ``widths``, clamped.
    public var widthIndex: Int {
        didSet { widthIndex = widthIndex.clamped(to: Self.widths.indices) }
    }

    /// Ink color.
    public var color: InkColor
    /// Pressure modulates width.
    public var pressure: Bool

    /// Base width in points.
    public var width: Float {
        Self.widths[widthIndex]
    }

    /// Creates pen settings (out-of-range values are normalized).
    public init(kind: PenKind = .fountain, widthIndex: Int = 1, color: InkColor = .primary, pressure: Bool = true) {
        self.kind = Self.kinds.contains(kind) ? kind : .fountain
        self.widthIndex = widthIndex.clamped(to: Self.widths.indices)
        self.color = color
        self.pressure = pressure
    }
}

/// Highlighter settings: width step and color.
public struct HighlighterSettings: Hashable, Sendable, Codable {
    /// Chisel widths in points, by ``widthIndex``.
    public static let widths: [Float] = [10, 16, 24]
    /// Mock highlighter yellow (`#FFD633`); translucency comes from the pen profile.
    public static let yellow = InkColor.custom(RGBA8(r: 0xFF, g: 0xD6, b: 0x33))

    /// Index into ``widths``, clamped.
    public var widthIndex: Int {
        didSet { widthIndex = widthIndex.clamped(to: Self.widths.indices) }
    }

    /// Highlight color.
    public var color: InkColor

    /// Width in points.
    public var width: Float {
        Self.widths[widthIndex]
    }

    /// Creates highlighter settings.
    public init(widthIndex: Int = 1, color: InkColor = HighlighterSettings.yellow) {
        self.widthIndex = widthIndex.clamped(to: Self.widths.indices)
        self.color = color
    }
}

/// Eraser settings: whole-stroke or partial, and a width step.
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

    /// Diameter in points.
    public var width: Float {
        Self.widths[widthIndex]
    }

    /// Creates eraser settings.
    public init(mode: Mode = .stroke, widthIndex: Int = 1) {
        self.mode = mode
        self.widthIndex = widthIndex.clamped(to: Self.widths.indices)
    }
}

/// Everything ``ToolState`` persists, as one Codable blob.
///
/// Decoding is lenient: missing or invalid fields fall back to the defaults passed to ``ToolState``, so
/// adding a field never wipes a user's settings.
public struct ToolSettings: Hashable, Sendable, Codable {
    /// Number of quick-color slots.
    public static let quickColorCount = 3

    /// Current tool.
    public var tool: Tool
    /// Pen settings.
    public var pen: PenSettings
    /// Highlighter settings.
    public var highlighter: HighlighterSettings
    /// Eraser settings.
    public var eraser: EraserSettings
    /// Quick-color slots, always ``quickColorCount`` long.
    public var quickColors: [InkColor] {
        didSet { quickColors = Self.normalized(quickColors) }
    }

    /// Toolbar dock.
    public var dock: ToolbarDock
    /// Toolbar pinched to the compact pill.
    public var isCompact: Bool

    /// Creates settings. `quickColors` is padded/truncated to ``quickColorCount``.
    public init(
        tool: Tool = .pen,
        pen: PenSettings = PenSettings(),
        highlighter: HighlighterSettings = HighlighterSettings(),
        eraser: EraserSettings = EraserSettings(),
        quickColors: [InkColor] = [.semantic(.primary), .semantic(.blue), .semantic(.red)],
        dock: ToolbarDock = .top,
        isCompact: Bool = false
    ) {
        self.tool = tool
        // Re-run the normalizing inits: synthesized decoding skips them.
        self.pen = PenSettings(kind: pen.kind, widthIndex: pen.widthIndex, color: pen.color, pressure: pen.pressure)
        self.highlighter = HighlighterSettings(widthIndex: highlighter.widthIndex, color: highlighter.color)
        self.eraser = EraserSettings(mode: eraser.mode, widthIndex: eraser.widthIndex)
        self.quickColors = Self.normalized(quickColors)
        self.dock = dock
        self.isCompact = isCompact
    }

    private static func normalized(_ colors: [InkColor]) -> [InkColor] {
        let defaults = ToolSettings.defaultQuickColors
        return (0 ..< quickColorCount).map { $0 < colors.count ? colors[$0] : defaults[$0] }
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
            quickColors: stored.quickColors ?? defaults.quickColors,
            dock: stored.dock ?? defaults.dock,
            isCompact: stored.isCompact ?? defaults.isCompact
        )
    }
}

/// Every field optional and individually lenient, so one bad field doesn't discard the rest.
private struct StoredToolSettings: Decodable {
    var tool: Tool?
    var pen: PenSettings?
    var highlighter: HighlighterSettings?
    var eraser: EraserSettings?
    var quickColors: [InkColor]?
    var dock: ToolbarDock?
    // swiftlint:disable:next discouraged_optional_boolean
    var isCompact: Bool?

    private enum CodingKeys: String, CodingKey {
        case tool, pen, highlighter, eraser, quickColors, dock, isCompact
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
        quickColors = field(.quickColors)
        dock = field(.dock)
        isCompact = field(.isCompact)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
