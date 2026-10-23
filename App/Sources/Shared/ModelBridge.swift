import DesignSystem
import InkModel

/// InkModel owns the data enums; DesignSystem owns their look. Same raw values on both sides.
extension InkModel.PaperTheme {
    var style: DesignSystem.PaperTheme {
        DesignSystem.PaperTheme(rawValue: rawValue) ?? .white
    }
}

extension DesignSystem.PaperTheme {
    var model: InkModel.PaperTheme {
        InkModel.PaperTheme(rawValue: rawValue) ?? .white
    }
}

extension PaperPattern {
    var model: PaperStyle {
        PaperStyle(rawValue: rawValue) ?? .blank
    }
}

extension InkModel.CoverColor {
    var style: DesignSystem.CoverColor {
        DesignSystem.CoverColor(rawValue: rawValue) ?? .sage
    }
}

extension PaperStyle {
    var pattern: PaperPattern {
        PaperPattern(rawValue: rawValue) ?? .blank
    }

    var displayName: String {
        pattern.displayName
    }

    /// Sheet offers four (§8); Cornell is per-page from the pages overview.
    static let sheetChoices: [PaperStyle] = [.blank, .lined, .dotted, .grid]
}
