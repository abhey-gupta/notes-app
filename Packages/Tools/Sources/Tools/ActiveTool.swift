import InkModel

/// What the Pencil does right now, with only the settings that tool uses (ARCHITECTURE.md §6). The editor
/// gets this one value from the toolbar; the engine configuration and the erase settings both come from it.
public enum ActiveTool: Hashable, Sendable {
    /// Ink: pen family (the highlighter is `.highlighter`), color, base width (pt), whether the
    /// Pencil's pressure modulates the width (#123; off draws every sample at neutral force), and the
    /// highlighter's nib (#215; pens ignore it).
    case ink(PenKind, color: InkColor, width: Float, pressure: Bool = true, nib: HighlighterNib = .chisel)
    /// Erase: whole strokes or partial, and the eraser's diameter.
    case eraser(EraserSettings)
    /// Lasso selection.
    case lasso
    /// Laser pointer (#159): drawn and faded by the engine, never saved.
    case laser(LaserSettings.Mode)

    /// Erasing (either mode).
    public var isEraser: Bool {
        if case .eraser = self {
            true
        } else {
            false
        }
    }
}

public extension ToolSettings {
    /// The current tool with its settings.
    var active: ActiveTool {
        switch tool {
        case .pen: .ink(pen.kind, color: pen.color, width: pen.width, pressure: pen.pressure)
        case .highlighter: .ink(.highlighter, color: highlighter.color, width: highlighter.width, nib: highlighter.nib)
        case .eraser: .eraser(eraser)
        case .lasso: .lasso
        case .laser: .laser(laser.mode)
        }
    }
}

public extension ToolState {
    /// The current tool with its settings; changes only when something that tool uses changes.
    var active: ActiveTool {
        settings.active
    }
}
