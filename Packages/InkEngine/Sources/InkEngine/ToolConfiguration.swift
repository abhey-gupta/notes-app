import InkModel

/// What the Pencil does right now.
public struct ToolConfiguration: Hashable, Sendable {
    /// Tool family. Engines draw pens and report eraser/lasso input; `Tools` interprets the latter. The
    /// laser is drawn and faded by the engine alone.
    public enum Tool: Hashable, Sendable {
        /// Ink with a pen profile.
        case pen(PenKind)
        /// Eraser input (stroke or partial is a `Tools` concern).
        case eraser
        /// Lasso selection path.
        case lasso
        /// Laser pointer (#159): a fading trail behind the tip, or (`trail` off) just a dot. Never committed.
        case laser(trail: Bool)
    }

    /// Tool family.
    public var tool: Tool
    /// Ink color for pens.
    public var color: InkColor
    /// Pen base width (pt, before profile modulation), or eraser diameter.
    public var width: Float
    /// "Draw with finger" setting (off by default, ARCHITECTURE.md §15.4). See ``InputPolicy``.
    public var allowsFingerDrawing: Bool
    /// Pressure modulates pen width (the pen popover's toggle, #123). Off: every sample is recorded at
    /// ``InkModel/Sample/neutralForce`` and the live stroke draws at constant width.
    public var pressure: Bool
    /// "Hold to snap shapes" setting (#165, on by default): a pen stroke held still at its end becomes a
    /// perfect line, ellipse or polygon.
    public var snapsShapes: Bool
    /// "Hold to erase" setting (#211, on by default): a pen touch held still where it went down becomes the
    /// eraser until it lifts.
    public var holdsToErase: Bool
    /// Highlighter nib shape (#215); pens ignore it.
    public var highlighterNib: HighlighterNib

    /// Creates a configuration.
    public init(
        tool: Tool,
        color: InkColor = .primary,
        width: Float = 2,
        allowsFingerDrawing: Bool = false,
        pressure: Bool = true,
        snapsShapes: Bool = true,
        holdsToErase: Bool = true,
        highlighterNib: HighlighterNib = .chisel
    ) {
        self.tool = tool
        self.color = color
        self.width = width
        self.allowsFingerDrawing = allowsFingerDrawing
        self.pressure = pressure
        self.snapsShapes = snapsShapes
        self.holdsToErase = holdsToErase
        self.highlighterNib = highlighterNib
    }

    /// Primary ballpoint, 2 pt.
    public static let `default` = ToolConfiguration(tool: .pen(.ballpoint))

    /// The pen kind, if the tool is a pen.
    public var penKind: PenKind? {
        if case let .pen(kind) = tool {
            kind
        } else {
            nil
        }
    }
}
