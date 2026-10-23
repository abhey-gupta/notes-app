import Foundation

/// OKLab lightness / chroma / hue (radians), for perceptual ink adaptation on Night paper (§10).
public struct OKLCH: Hashable, Sendable {
    public var lightness: Double
    public var chroma: Double
    public var hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }
}

public extension RGBA {
    var oklch: OKLCH {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lab = (
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
        return OKLCH(lightness: lab.l, chroma: hypot(lab.a, lab.b), hue: atan2(lab.b, lab.a))
    }

    init(_ lch: OKLCH, alpha: Double = 1) {
        let a = lch.chroma * cos(lch.hue), bb = lch.chroma * sin(lch.hue)
        let l = pow(lch.lightness + 0.3963377774 * a + 0.2158037573 * bb, 3)
        let m = pow(lch.lightness - 0.1055613458 * a - 0.0638541728 * bb, 3)
        let s = pow(lch.lightness - 0.0894841775 * a - 1.2914855480 * bb, 3)
        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return min(max(v, 0), 1)
        }
        self.init(
            red: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            alpha: alpha
        )
    }

    /// Night-paper remap (§10): dark colors mirror to light, light colors stay; never darker.
    /// `L' = clamp(max(L, 1.2 − L), 0.65, 0.95)`, hue and chroma kept.
    func remappedForNight() -> RGBA {
        var lch = oklch
        lch.lightness = min(max(max(lch.lightness, 1.2 - lch.lightness), 0.65), 0.95)
        return RGBA(lch, alpha: alpha)
    }
}

public extension PaperTheme {
    /// A custom (non-semantic) color as it should appear on this paper.
    func adapt(_ color: RGBA, keepExact: Bool = false) -> RGBA {
        isDark && !keepExact ? color.remappedForNight() : color
    }

    /// The 11-color palette as shown on this paper.
    var palette: [RGBA] {
        Tokens.palette.map { adapt($0) }
    }
}
