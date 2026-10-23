import CoreGraphics
import DesignSystem
import Export
import InkModel

/// Feeds `DesignSystem` tokens to the headless PDF exporter (hex values stay in `DesignSystem`, §10).
struct DesignSystemPDFPalette: PDFPalette {
    func paper(_ theme: InkModel.PaperTheme) -> CGColor {
        Self.paper(theme).paper.cgColor
    }

    func templateLine(_ theme: InkModel.PaperTheme) -> CGColor {
        Self.paper(theme).templateLine.cgColor
    }

    func ink(_ color: InkColor, on theme: InkModel.PaperTheme, keepsExactColors: Bool) -> CGColor {
        let paper = Self.paper(theme)
        switch color {
        case let .semantic(slot):
            return paper.ink(Self.role(slot)).cgColor
        case let .custom(c):
            let rgba = RGBA(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: Double(c.a) / 255)
            return paper.adapt(rgba, keepExact: keepsExactColors).cgColor
        }
    }

    private static func paper(_ theme: InkModel.PaperTheme) -> DesignSystem.PaperTheme {
        switch theme {
        case .white: .white
        case .cream: .cream
        case .night: .night
        }
    }

    private static func role(_ slot: SemanticInk) -> InkRole {
        switch slot {
        case .primary: .primary
        case .blue: .blue
        case .red: .red
        case .accent: .accent
        }
    }
}
