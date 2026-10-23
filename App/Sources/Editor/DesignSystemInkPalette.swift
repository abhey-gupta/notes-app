import DesignSystem
import InkEngine
import InkModel

/// Feeds `DesignSystem` tokens to the ink engines (hex values stay in `DesignSystem`, §10). Same mapping
/// as `DesignSystemPDFPalette`: semantic ink per paper, custom colors lightness-remapped on Night unless
/// the notebook keeps exact colors.
struct DesignSystemInkPalette: InkPalette {
    /// The notebook's "Keep exact colors" setting.
    var keepsExactColors = false

    func paper(_ theme: InkModel.PaperTheme) -> RGBA8 {
        RGBA8(theme.style.paper)
    }

    func templateLine(_ theme: InkModel.PaperTheme) -> RGBA8 {
        RGBA8(theme.style.templateLine)
    }

    func ink(_ color: InkColor, on theme: InkModel.PaperTheme) -> RGBA8 {
        let paper = theme.style
        switch color {
        case let .semantic(slot):
            return RGBA8(paper.ink(slot.role))
        case let .custom(c):
            let rgba = RGBA(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: Double(c.a) / 255)
            return RGBA8(paper.adapt(rgba, keepExact: keepsExactColors))
        }
    }
}
