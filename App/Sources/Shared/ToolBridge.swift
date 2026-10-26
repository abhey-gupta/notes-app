import DesignSystem
import InkEngine
import InkModel
import SwiftUI
import Tools

extension ActiveTool {
    /// What the engine needs (§6): a pen profile (the highlighter is one) with its color and width, the
    /// eraser's diameter, or the lasso. Stroke vs partial erase stays with the session.
    func configuration(allowsFingerDrawing: Bool) -> ToolConfiguration {
        switch self {
        case let .ink(kind, color, width, pressure):
            ToolConfiguration(tool: .pen(kind), color: color, width: width, allowsFingerDrawing: allowsFingerDrawing, pressure: pressure)
        case let .eraser(eraser):
            ToolConfiguration(tool: .eraser, width: eraser.width, allowsFingerDrawing: allowsFingerDrawing)
        case .lasso:
            ToolConfiguration(tool: .lasso, allowsFingerDrawing: allowsFingerDrawing)
        }
    }
}

/// Tools owns tool data and placement; DesignSystem owns their look. This is the seam.
extension ToolSettings {
    /// App defaults: quick colors from `Tokens.quickColors`, highlighter from `Tokens.highlighter`.
    static var notespace: ToolSettings {
        let yellow = Tokens.highlighter
        return ToolSettings(
            highlighter: HighlighterSettings(color: .custom(RGBA8(yellow.opacity(1)))),
            quickColors: Tokens.quickColors.map { .semantic($0.semantic) }
        )
    }
}

extension InkColor {
    /// Resolved for `paper` (semantic slots remap on Night, §10).
    func color(on paper: DesignSystem.PaperTheme) -> Color {
        switch self {
        case let .semantic(slot): paper.ink(slot.role).color
        case let .custom(rgba): Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
        }
    }

    /// VoiceOver name for a quick-color swatch.
    var label: String {
        switch self {
        case .semantic(.primary): "Black"
        case .semantic(.blue): "Blue"
        case .semantic(.red): "Red"
        case .semantic(.accent): "Amber"
        case .custom: accessibilityName
        }
    }

    /// Spoken color name: the palette's name when it is a palette color, else "Custom color".
    var accessibilityName: String {
        if case .semantic = self {
            return label
        }
        let entry = PaletteEntry.pen.first { $0.color == self } ?? PaletteEntry.highlighter.first { $0.color == self }
        return entry?.name ?? "Custom color"
    }
}

extension SemanticInk {
    var role: InkRole {
        switch self {
        case .primary: .primary
        case .blue: .blue
        case .red: .red
        case .accent: .accent
        }
    }
}

extension InkRole {
    var semantic: SemanticInk {
        switch self {
        case .primary: .primary
        case .blue: .blue
        case .red: .red
        case .accent: .accent
        }
    }
}

extension RGBA8 {
    init(_ rgba: RGBA) {
        func byte(_ v: Double) -> UInt8 {
            UInt8((min(max(v, 0), 1) * 255).rounded())
        }
        self.init(r: byte(rgba.red), g: byte(rgba.green), b: byte(rgba.blue), a: byte(rgba.alpha))
    }
}

extension Tool {
    var symbol: Symbol {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .eraser: .eraser
        case .lasso: .lasso
        }
    }

    var label: String {
        rawValue.capitalized
    }
}

extension ToolState {
    /// VoiceOver value of `tool`'s button (#45): "Fountain pen, Black, width 2.5", "Stroke eraser, size 16".
    func accessibilityValue(of tool: Tool) -> String {
        switch tool {
        case .pen:
            "\(pen.kind.displayName) pen, \(pen.color.accessibilityName), width \(pen.width.formatted())"
        case .highlighter:
            "\(highlighter.color.accessibilityName), width \(highlighter.width.formatted())"
        case .eraser:
            "\(eraser.mode.displayName) eraser, size \(eraser.width.formatted())"
        case .lasso:
            ""
        }
    }
}

extension ToolbarDock {
    var axis: Axis {
        isVertical ? .vertical : .horizontal
    }

    var displayName: String {
        rawValue.capitalized
    }

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}
