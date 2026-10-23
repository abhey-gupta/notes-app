import InkModel

/// One writer's habits, fixed per notebook so every page looks like the same person wrote it.
struct Hand {
    /// x-height multiplier on the template's natural size.
    var size: Float
    /// Rightward lean: x offset per point of height above the baseline.
    var slant: Float
    /// Mean letter advance, in x-heights.
    var letterWidth: Float
    /// Gap between words, in x-heights.
    var wordGap: Float
    /// Samples per letter (Pencil reports ~240 Hz; coalesced/filtered input lands near this).
    var samplesPerLetter: Int
    /// Seconds per letter.
    var letterDuration: Float
    /// Mean normalized force.
    var pressure: Float
    /// Pencil altitude (rad).
    var altitude: Float
    /// Pencil azimuth (rad, page space).
    var azimuth: Float
    /// Body ink.
    var body: InkStyle

    init(_ rng: inout SeededRandom) {
        size = rng.float(0.9 ... 1.1)
        slant = rng.float(0.08 ... 0.32)
        letterWidth = rng.float(0.75 ... 0.95)
        wordGap = rng.float(0.9 ... 1.3)
        samplesPerLetter = rng.int(14 ... 18)
        letterDuration = rng.float(0.11 ... 0.17)
        pressure = rng.float(0.35 ... 0.6)
        altitude = rng.float(0.85 ... 1.15)
        azimuth = rng.float(-0.9 ... -0.2)
        body = InkStyle.body(rng.weighted([5, 3.5, 1.5]), &rng)
    }
}

/// Pen, color and width of a stroke.
struct InkStyle {
    var tool: PenKind
    var color: InkColor
    var width: Float

    /// Writing pen: fountain, ballpoint or brush (`kind` 0, 1, 2), in a mostly-dark ink.
    static func body(_ kind: Int, _ rng: inout SeededRandom) -> InkStyle {
        let color: InkColor = switch rng.weighted([80, 12, 4, 4]) {
        case 0: .primary
        case 1: .semantic(.blue)
        case 2: .custom(RGBA8(r: 0x1F, g: 0x4E, b: 0x3D))
        default: .custom(RGBA8(r: 0x3A, g: 0x2A, b: 0x6B))
        }
        return switch kind {
        case 0: InkStyle(tool: .fountain, color: color, width: rng.float(1.6 ... 2.4))
        case 1: InkStyle(tool: .ballpoint, color: color, width: rng.float(1.1 ... 1.7))
        default: InkStyle(tool: .brush, color: color, width: rng.float(2.4 ... 3.6))
        }
    }

    /// Same pen, accent color: headings and diagrams.
    func accent(_ rng: inout SeededRandom) -> InkStyle {
        var style = self
        style.color = rng.pick([.semantic(.blue), .semantic(.red), .primary, .custom(RGBA8(r: 0x0E, g: 0x6E, b: 0x7A))])
        return style
    }

    /// Chisel highlighter in a pale marker color.
    static func highlighter(_ rng: inout SeededRandom) -> InkStyle {
        let color: InkColor = rng.pick([
            .semantic(.accent),
            .custom(RGBA8(r: 0xFF, g: 0xE4, b: 0x5C)),
            .custom(RGBA8(r: 0xB8, g: 0xF2, b: 0x8C)),
            .custom(RGBA8(r: 0xFF, g: 0xB3, b: 0xD9)),
        ])
        return InkStyle(tool: .highlighter, color: color, width: rng.float(13 ... 18))
    }
}
