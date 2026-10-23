import DesignSystem
import SwiftUI

/// Procedural stand-in "handwriting" for fixture notebooks until real strokes and thumbnails exist (#21, #34).
/// Drawn in A4 page points (595×842); callers scale the context. Deterministic per kind + page.
enum SampleInk {
    enum Kind: Hashable {
        case lecture, wireframe, journal, mindMap
    }

    static let pageSize = Tokens.Size.pageA4

    /// Draws page `page` of a `kind` notebook into `context`, which must already be scaled to page points.
    static func draw(_ kind: Kind, page: Int, paper: PaperTheme, in context: GraphicsContext) {
        var pen = Pen(context: context, paper: paper, seed: UInt64(page + 1) &* 0x9E37_79B9_7F4A_7C15 ^ kind.seed)
        switch (kind, page) {
        case (.lecture, 0): pen.lecture()
        case (.wireframe, 0): pen.wireframe()
        case (.mindMap, 0): pen.mindMap()
        default: pen.notes(title: page == 0 || page % 3 == 0)
        }
    }
}

private extension SampleInk.Kind {
    var seed: UInt64 {
        switch self {
        case .lecture: 11
        case .wireframe: 23
        case .journal: 37
        case .mindMap: 53
        }
    }
}

/// SplitMix64: tiny deterministic RNG.
private struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }

    mutating func range(_ range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    mutating func chance(_ probability: CGFloat) -> Bool {
        unit() < probability
    }
}

private struct Pen {
    var context: GraphicsContext
    let paper: PaperTheme
    var random: SeededRandom

    init(context: GraphicsContext, paper: PaperTheme, seed: UInt64) {
        self.context = context
        self.paper = paper
        random = SeededRandom(state: seed)
    }

    private func ink(_ role: InkRole) -> Color {
        paper.ink(role).color
    }

    private var muted: Color {
        paper.ink(.primary).color.opacity(0.45)
    }

    // MARK: Primitives

    /// Cursive-looking line: prolate trochoid loops per letter, words of random length, slight slant.
    mutating func scribble(x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat) -> Path {
        var path = Path()
        var cursor = x
        while cursor < x + width - size * 2 {
            let letters = Int(random.range(2 ... 8))
            let baseline = y + random.range(-1 ... 1)
            var first = true
            for _ in 0 ..< letters {
                let tall = random.chance(0.2), descends = !tall && random.chance(0.12)
                let height = size * (tall ? 2 : 1) * random.range(0.75 ... 1.1)
                // Loop factor: < 0.16 reads as humps (n, m), above as loops (e, l); vary per letter.
                let letter = size * random.range(0.45 ... 0.85)
                let loop = tall || descends ? random.range(0.25 ... 0.4) : random.range(0.04 ... 0.36)
                let steps = 10
                for step in 0 ... steps {
                    let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
                    let lift = height * (1 - cos(t)) / 2
                    let py = descends ? baseline + lift * 0.8 : baseline - lift
                    let px = cursor + letter * t / (2 * .pi) - letter * loop * sin(t) + (baseline - py) * 0.25
                    let point = CGPoint(x: px, y: py)
                    if first {
                        path.move(to: point)
                        first = false
                    } else {
                        path.addLine(to: point)
                    }
                }
                cursor += letter
            }
            cursor += size * random.range(0.8 ... 1.3)
        }
        return path
    }

    mutating func write(_ x: CGFloat, _ y: CGFloat, width: CGFloat, size: CGFloat = 7, color: Color? = nil, weight: CGFloat = 1.3) {
        let path = scribble(x: x, y: y, width: width, size: size)
        stroke(path, color ?? ink(.primary), weight)
    }

    func stroke(_ path: Path, _ color: Color, _ width: CGFloat, dash: [CGFloat] = []) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }

    mutating func wave(_ x: CGFloat, _ y: CGFloat, width: CGFloat, color: Color, weight: CGFloat = 2.2) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addCurve(
            to: CGPoint(x: x + width, y: y - 1),
            control1: CGPoint(x: x + width * 0.3, y: y - 4),
            control2: CGPoint(x: x + width * 0.6, y: y + 4)
        )
        stroke(path, color, weight)
    }

    func highlight(_ rect: CGRect) {
        var layer = context
        layer.blendMode = paper.isDark ? .screen : .multiply
        layer.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Tokens.highlighter.color.opacity(paper.isDark ? 0.45 : 1)))
    }

    func bullet(_ x: CGFloat, _ y: CGFloat) {
        context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(ink(.primary)))
    }

    // MARK: Pages

    mutating func lecture() {
        write(440, 40, width: 110, size: 5, color: muted, weight: 1)
        write(50, 62, width: 330, size: 13, weight: 2.4)
        wave(48, 78, width: 340, color: ink(.blue), weight: 2.5)

        bullet(58, 128)
        write(68, 132, width: 230, size: 7.5)
        write(86, 172, width: 100, size: 10, color: ink(.red), weight: 2)
        var box = Path()
        box.move(to: CGPoint(x: 76, y: 150))
        box.addCurve(to: CGPoint(x: 222, y: 152), control1: CGPoint(x: 120, y: 147), control2: CGPoint(x: 180, y: 149))
        box.addCurve(to: CGPoint(x: 220, y: 188), control1: CGPoint(x: 225, y: 164), control2: CGPoint(x: 224, y: 176))
        box.addCurve(to: CGPoint(x: 74, y: 187), control1: CGPoint(x: 170, y: 190), control2: CGPoint(x: 110, y: 189))
        box.addCurve(to: CGPoint(x: 77, y: 148), control1: CGPoint(x: 72, y: 175), control2: CGPoint(x: 73, y: 160))
        stroke(box, ink(.red), 1.9)

        highlight(CGRect(x: 214, y: 210, width: 70, height: 13))
        bullet(58, 220)
        write(68, 224, width: 220, size: 7.5)
        bullet(58, 258)
        write(68, 262, width: 250, size: 7.5)
        write(86, 298, width: 220, size: 6.5, color: ink(.primary).opacity(0.7))

        chart(at: CGPoint(x: 330, y: 330))

        for (index, width) in [170.0, 160, 150].enumerated() {
            write(58, 370 + CGFloat(index) * 34, width: width, size: 7, color: ink(.blue))
        }
        var arrow = Path()
        arrow.move(to: CGPoint(x: 240, y: 438))
        arrow.addCurve(to: CGPoint(x: 330, y: 405), control1: CGPoint(x: 270, y: 446), control2: CGPoint(x: 305, y: 438))
        arrow.move(to: CGPoint(x: 318, y: 402))
        arrow.addLine(to: CGPoint(x: 331, y: 404))
        arrow.addLine(to: CGPoint(x: 328, y: 417))
        stroke(arrow, ink(.blue), 1.9)

        bullet(58, 506)
        write(68, 510, width: 240, size: 7.5)
        star(at: CGPoint(x: 38, y: 506))
        for line in 0 ..< 6 {
            write(58, 560 + CGFloat(line) * 36, width: random.range(260 ... 470), size: 7)
        }
    }

    func chart(at origin: CGPoint) {
        let ox = origin.x, oy = origin.y
        var axes = Path()
        axes.move(to: CGPoint(x: ox + 25, y: oy + 12))
        axes.addQuadCurve(to: CGPoint(x: ox + 26, y: oy + 170), control: CGPoint(x: ox + 23, y: oy + 90))
        axes.addQuadCurve(to: CGPoint(x: ox + 236, y: oy + 166), control: CGPoint(x: ox + 130, y: oy + 172))
        stroke(axes, ink(.primary), 2)
        var fill = Path()
        fill.move(to: CGPoint(x: ox + 50, y: oy + 34))
        fill.addCurve(
            to: CGPoint(x: ox + 210, y: oy + 148),
            control1: CGPoint(x: ox + 72, y: oy + 110),
            control2: CGPoint(x: ox + 124, y: oy + 140)
        )
        fill.addLine(to: CGPoint(x: ox + 210, y: oy + 168))
        fill.addLine(to: CGPoint(x: ox + 50, y: oy + 168))
        fill.closeSubpath()
        context.fill(fill, with: .color(ink(.blue).opacity(0.1)))
        var iso = Path()
        iso.move(to: CGPoint(x: ox + 50, y: oy + 34))
        iso.addCurve(
            to: CGPoint(x: ox + 210, y: oy + 148),
            control1: CGPoint(x: ox + 72, y: oy + 110),
            control2: CGPoint(x: ox + 124, y: oy + 140)
        )
        stroke(iso, ink(.blue), 2.6)
        var adiabat = Path()
        adiabat.move(to: CGPoint(x: ox + 50, y: oy + 34))
        adiabat.addCurve(
            to: CGPoint(x: ox + 170, y: oy + 160),
            control1: CGPoint(x: ox + 61, y: oy + 118),
            control2: CGPoint(x: ox + 100, y: oy + 154)
        )
        stroke(adiabat, ink(.red), 2, dash: [5, 5])
        for point in [CGPoint(x: ox + 50, y: oy + 34), CGPoint(x: ox + 210, y: oy + 148)] {
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(ink(.primary)))
        }
    }

    func star(at center: CGPoint) {
        var path = Path()
        for index in 0 ... 10 {
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            let radius: CGFloat = index.isMultiple(of: 2) ? 11 : 5
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        stroke(path, ink(.accent), 1.8)
    }

    mutating func wireframe() {
        write(50, 62, width: 220, size: 13, weight: 2.4)
        for column in 0 ..< 3 {
            let x = 50 + CGFloat(column) * 170
            stroke(Path(roundedRect: CGRect(x: x, y: 110, width: 120, height: 200), cornerRadius: 16), ink(.primary), 1.7)
            stroke(Path(CGRect(x: x + 14, y: 132, width: 92, height: 56)), ink(.primary).opacity(0.35), 1.2)
            write(x + 14, 214, width: 92, size: 5)
            write(x + 14, 236, width: 70, size: 5, color: muted)
            if column < 2 {
                var arrow = Path()
                arrow.move(to: CGPoint(x: x + 128, y: 210))
                arrow.addLine(to: CGPoint(x: x + 162, y: 210))
                arrow.move(to: CGPoint(x: x + 154, y: 203))
                arrow.addLine(to: CGPoint(x: x + 163, y: 210))
                arrow.addLine(to: CGPoint(x: x + 154, y: 217))
                stroke(arrow, ink(.blue), 1.8)
            }
        }
        stroke(Path(roundedRect: CGRect(x: 64, y: 272, width: 92, height: 22), cornerRadius: 11), ink(.red), 1.7)
        for line in 0 ..< 8 {
            if line == 3 {
                bullet(58, 400 + CGFloat(line) * 34)
            }
            write(68, 404 + CGFloat(line) * 34, width: random.range(220 ... 440), size: 7)
        }
    }

    mutating func mindMap() {
        write(50, 62, width: 230, size: 13, weight: 2.4)
        let center = CGPoint(x: 297, y: 330)
        var blob = Path()
        blob.addEllipse(in: CGRect(x: center.x - 80, y: center.y - 42, width: 160, height: 84))
        stroke(blob, ink(.primary), 2.2)
        write(center.x - 46, center.y + 6, width: 100, size: 10, weight: 2.2)
        let branches: [(CGPoint, InkRole)] = [
            (CGPoint(x: 70, y: 150), .blue), (CGPoint(x: 360, y: 150), .red),
            (CGPoint(x: 70, y: 470), .accent), (CGPoint(x: 360, y: 470), .blue),
        ]
        for (origin, role) in branches {
            var line = Path()
            let left = origin.x < 200, top = origin.y < 300
            let start = CGPoint(x: center.x + (left ? -62 : 62), y: center.y + (top ? -24 : 24))
            let end = CGPoint(x: left ? origin.x + 156 : origin.x - 6, y: top ? origin.y + 18 : origin.y - 22)
            line.move(to: start)
            line.addQuadCurve(to: end, control: CGPoint(x: start.x, y: end.y))
            stroke(line, ink(.primary).opacity(0.7), 1.5)
            write(origin.x, origin.y, width: 110, size: 9, color: ink(role), weight: 1.8)
            wave(origin.x, origin.y + 12, width: 150, color: ink(role), weight: 2)
            for row in 0 ..< 3 {
                write(
                    origin.x + 4,
                    origin.y + 40 + CGFloat(row) * 24,
                    width: random.range(90 ... 140),
                    size: 5.5,
                    color: ink(.primary).opacity(0.85)
                )
            }
        }
    }

    mutating func notes(title: Bool) {
        var y: CGFloat = 70
        if title {
            write(50, y, width: random.range(180 ... 300), size: 12, weight: 2.2)
            y += 56
        }
        let lines = Int(random.range(9 ... 15))
        for _ in 0 ..< lines {
            write(58, y, width: random.range(240 ... 480), size: 7)
            y += 34
        }
        if random.chance(0.5) {
            highlight(CGRect(x: 120, y: 70 + (title ? 56 : 0) + 34 * 2 - 10, width: 90, height: 13))
        }
    }
}
