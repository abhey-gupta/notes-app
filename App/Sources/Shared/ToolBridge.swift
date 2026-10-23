import DesignSystem
import InkEngine
import InkModel
import SwiftUI
import Tools

extension ToolState {
    /// What the engine needs for the current tool (§6): pen kind, width and color; the highlighter as a pen
    /// profile; the eraser's diameter.
    func configuration(allowsFingerDrawing: Bool) -> ToolConfiguration {
        switch tool {
        case .pen:
            ToolConfiguration(tool: .pen(pen.kind), color: pen.color, width: pen.width, allowsFingerDrawing: allowsFingerDrawing)
        case .highlighter:
            ToolConfiguration(
                tool: .pen(.highlighter), color: highlighter.color, width: highlighter.width, allowsFingerDrawing: allowsFingerDrawing
            )
        case .eraser:
            ToolConfiguration(tool: .eraser, color: pen.color, width: eraser.width, allowsFingerDrawing: allowsFingerDrawing)
        case .lasso:
            ToolConfiguration(tool: .lasso, color: pen.color, width: 1, allowsFingerDrawing: allowsFingerDrawing)
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
        case .custom: "Custom color"
        }
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
