/// Pen family. Raw values are stable (stroke codec stores them as `u8`).
public enum PenKind: UInt8, CaseIterable, Hashable, Sendable, Codable {
    /// Pressure + velocity modulated, thick/thin ink.
    case fountain = 0
    /// Near-constant width.
    case ballpoint = 1
    /// Pressure + tilt widen, soft edge.
    case brush = 2
    /// Constant-width chisel, translucent, drawn beneath ink.
    case highlighter = 3
}

/// Theme-adaptive palette slot, resolved per paper theme at render time (ARCHITECTURE.md §10).
/// Raw values are stable (stroke codec).
public enum SemanticInk: UInt8, CaseIterable, Hashable, Sendable, Codable {
    /// Near-black on light paper, off-white on Night.
    case primary = 0
    /// Blue on light paper, teal on Night.
    case blue = 1
    /// Red on light paper, pink on Night.
    case red = 2
    /// Amber.
    case accent = 3
}

/// 8-bit-per-channel sRGB color with straight (non-premultiplied) alpha.
public struct RGBA8: Hashable, Sendable, Codable {
    /// Red channel.
    public var r: UInt8
    /// Green channel.
    public var g: UInt8
    /// Blue channel.
    public var b: UInt8
    /// Alpha channel.
    public var a: UInt8

    /// Creates a color from channels.
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Creates a color from `0xRRGGBBAA`.
    public init(rgba: UInt32) {
        self.init(
            r: UInt8(truncatingIfNeeded: rgba >> 24),
            g: UInt8(truncatingIfNeeded: rgba >> 16),
            b: UInt8(truncatingIfNeeded: rgba >> 8),
            a: UInt8(truncatingIfNeeded: rgba)
        )
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (leading `#` optional, case-insensitive).
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(rgba: digits.count == 6 ? value << 8 | 0xFF : value)
    }

    /// Packed `0xRRGGBBAA`.
    public var rgba: UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
    }

    /// `#RRGGBBAA`, uppercase.
    public var hex: String {
        let digits = String(rgba, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 8 - digits.count) + digits
    }
}

/// A stroke's color: a theme-adaptive palette slot or an exact custom color (ARCHITECTURE.md §10).
///
/// Encodes as a single string: the semantic name (`"primary"`) or `"#RRGGBBAA"`.
public enum InkColor: Hashable, Sendable, Codable {
    /// Palette slot resolved per paper theme.
    case semantic(SemanticInk)
    /// Exact color (lightness-remapped on Night unless the notebook keeps exact colors).
    case custom(RGBA8)

    /// Shorthand for `.semantic(.primary)`.
    public static let primary = InkColor.semantic(.primary)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let slot = SemanticInk.allCases.first(where: { string == "\($0)" }) {
            self = .semantic(slot)
        } else if let color = RGBA8(hex: string) {
            self = .custom(color)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid InkColor \(string)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .semantic(slot): try container.encode("\(slot)")
        case let .custom(color): try container.encode(color.hex)
        }
    }
}
