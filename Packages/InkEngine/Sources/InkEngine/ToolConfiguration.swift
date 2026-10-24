import InkModel

/// What the Pencil does right now.
public struct ToolConfiguration: Hashable, Sendable {
    /// Tool family. Engines draw pens and report eraser/lasso input; `Tools` interprets the latter.
    public enum Tool: Hashable, Sendable {
        /// Ink with a pen profile.
        case pen(PenKind)
        /// Eraser input (stroke or partial is a `Tools` concern).
        case eraser
        /// Lasso selection path.
        case lasso
    }

    /// Tool family.
    public var tool: Tool
    /// Ink color for pens.
    public var color: InkColor
    /// Pen base width (pt, before profile modulation), or eraser diameter.
    public var width: Float
    /// "Draw with finger" setting (off by default, ARCHITECTURE.md §15.4). See ``InputPolicy``.
    public var allowsFingerDrawing: Bool

    /// Creates a configuration.
    public init(tool: Tool, color: InkColor = .primary, width: Float = 2, allowsFingerDrawing: Bool = false) {
        self.tool = tool
        self.color = color
        self.width = width
        self.allowsFingerDrawing = allowsFingerDrawing
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
