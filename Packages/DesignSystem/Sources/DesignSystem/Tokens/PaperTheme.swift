import SwiftUI

/// Per-notebook paper. Independent of system appearance: Night paper stays dark in light mode and vice versa.
public enum PaperTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case white, cream, night

    public var id: Self {
        self
    }

    public var displayName: String {
        switch self {
        case .white: "White"
        case .cream: "Cream"
        case .night: "Night"
        }
    }

    public var isDark: Bool {
        self == .night
    }

    public var paper: RGBA {
        switch self {
        case .white: RGBA(0xFFFFFF)
        case .cream: RGBA(0xF6F0E1)
        case .night: RGBA(0x1B1C1F)
        }
    }

    /// Semantic ink resolved for this paper (near-black on cream, off-white on Night).
    public func ink(_ role: InkRole) -> RGBA {
        let colors = switch role {
        case .primary: Tokens.Colors.inkPrimary
        case .blue: Tokens.Colors.inkBlue
        case .red: Tokens.Colors.inkRed
        case .accent: Tokens.Colors.inkAccent
        }
        return isDark ? colors.dark : colors.light
    }

    /// Dots / lines / grid.
    public var templateLine: RGBA {
        isDark ? Tokens.Colors.templateLine.dark : Tokens.Colors.templateLine.light
    }

    public var pageShadow: ShadowToken {
        isDark ? Tokens.Shadows.pageNight : Tokens.Shadows.page
    }

    /// Thin edge so the page separates from the desk where the shadow can't (Night on a dark desk).
    public var pageEdge: RGBA {
        isDark ? RGBA(0xFFFFFF, alpha: 0.06) : RGBA(0x000000, alpha: 0.04)
    }
}

/// Notebook cover colors (8).
public enum CoverColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case sage, terracotta, navy, sand, plum, graphite, sky, rose

    public var id: Self {
        self
    }

    public var rgba: RGBA {
        switch self {
        case .sage: RGBA(0x8E9F87)
        case .terracotta: RGBA(0xC07F5E)
        case .navy: RGBA(0x2F3B57)
        case .sand: RGBA(0xD9C9AC)
        case .plum: RGBA(0x6B4A5E)
        case .graphite: RGBA(0x3B3C40)
        case .sky: RGBA(0x9DB4C9)
        case .rose: RGBA(0xE3A5A0)
        }
    }

    public var color: Color {
        rgba.color
    }

    /// Paper label stuck on the cover.
    public static let label = RGBA(0xFCFBF7, alpha: 0.92)
    public static let labelText = RGBA(0x2A2A2A)
    public static let labelCaption = RGBA(0x888888)
}
