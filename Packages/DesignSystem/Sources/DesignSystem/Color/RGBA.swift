import SwiftUI
import UIKit

/// A concrete sRGB color. The only way hex values enter the app; everything else reads tokens.
public struct RGBA: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `RGBA(0x1E2129)`; alpha separate so `rgba(0,0,0,.07)` reads as `RGBA(0x000000, alpha: 0.07)`.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public func opacity(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Packed `0xRRGGBB` (alpha dropped), for persistence and debugging.
    public var hex: UInt32 {
        func byte(_ v: Double) -> UInt32 {
            UInt32((min(max(v, 0), 1) * 255).rounded())
        }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// Source-over onto an opaque `backdrop`: what a translucent fill looks like on a page.
    public func composited(over backdrop: RGBA) -> RGBA {
        RGBA(
            red: red * alpha + backdrop.red * (1 - alpha),
            green: green * alpha + backdrop.green * (1 - alpha),
            blue: blue * alpha + backdrop.blue * (1 - alpha)
        )
    }

    /// WCAG 2.x relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrastRatio(against other: RGBA) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A light/dark pair that follows system appearance. Usable directly as a `ShapeStyle`.
public struct DynamicColor: Hashable, Sendable, ShapeStyle {
    public var light: RGBA
    public var dark: RGBA

    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    public init(_ both: RGBA) {
        self.init(light: both, dark: both)
    }

    public func resolved(for scheme: ColorScheme) -> RGBA {
        scheme == .dark ? dark : light
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        resolved(for: environment.colorScheme).color
    }

    /// Dynamic `Color` (resolves against the trait collection it is drawn in).
    public var color: Color {
        Color(uiColor: uiColor)
    }

    /// Dynamic `UIColor` for UIKit/Metal hosts.
    public var uiColor: UIColor {
        let light = light, dark = dark
        return UIColor { $0.userInterfaceStyle == .dark ? dark.uiColor : light.uiColor }
    }
}
