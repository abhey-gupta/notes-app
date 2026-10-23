import Foundation
import InkModel

/// Lays out one page of notes for its template and writes it with an ``InkWriter``: a heading, paragraphs
/// and lists in lines with word gaps, occasional highlights, Cornell cues and summary, and sometimes a
/// box-and-arrow diagram. Stops at exactly `target` strokes.
struct PageComposer {
    private var ink: InkWriter
    private let template: PageTemplate
    private let size: (width: Float, height: Float)
    private let target: Int
    private var style: InkStyle

    init(ink: InkWriter, template: PageTemplate, pageSize: (width: Float, height: Float), target: Int) {
        self.ink = ink
        self.template = template
        size = pageSize
        self.target = target
        style = ink.hand.body
        // Some pages are written with a different pen.
        if self.ink.rng.chance(0.15) {
            style = InkStyle.body(self.ink.rng.weighted([5, 3.5, 1.5]), &self.ink.rng)
        }
    }

    private enum Region { case body, cue, summary }

    private struct Slot {
        var line: TextLine
        var region: Region
    }

    private var isFull: Bool {
        ink.strokes.count >= target
    }

    /// Smallest letter-width factor: below this, text stops looking like writing.
    private static let minDensity: Float = 0.45

    consuming func compose() -> [Stroke] {
        guard target > 0 else { return [] }
        // Fit the target on one pass over the page's lines, retrying tighter if the estimate was short.
        let start = ink
        var scale: Float = 1
        for _ in 0 ..< 4 {
            ink = start
            let density = write(layout(pass: 0), firstPass: true, densityScale: scale)
            if isFull || density <= Self.minDensity {
                break
            }
            scale *= max(0.6, Float(ink.strokes.count) / Float(target)) * 0.97
        }
        // Targets beyond what the page holds even at minimum density: squeeze notes between the lines.
        var pass = 1
        while !isFull, pass < 8 {
            let before = ink.strokes.count
            write(layout(pass: pass), firstPass: false, densityScale: 1)
            if ink.strokes.count == before {
                break
            }
            pass += 1
        }
        return Array(ink.strokes.prefix(target))
    }

    // MARK: Writing

    /// Writes `slots` until the page is full; returns the letter-width factor used.
    @discardableResult
    private mutating func write(_ slots: [Slot], firstPass: Bool, densityScale: Float) -> Float {
        let bodyIndices = slots.indices.filter { slots[$0].region == .body }
        // Reserve a block of lines for a diagram on some pages.
        var diagram: Range<Int>?
        if firstPass, bodyIndices.count >= 16, ink.rng.chance(0.3) {
            let length = ink.rng.int(6 ... 8)
            let start = bodyIndices[ink.rng.int(3 ... bodyIndices.count - length - 1)]
            diagram = start ..< start + length
        }
        let density = max(Self.minDensity, fitDensity(slots, skipping: diagram) * densityScale)
        var listLeft = 0
        var dotBullets = true
        var headingDone = !firstPass
        var i = 0
        while i < slots.count, !isFull {
            let slot = slots[i]
            if let block = diagram, block.lowerBound == i {
                drawDiagram(in: slots[block])
                i = block.upperBound
                continue
            }
            switch slot.region {
            case .cue:
                writeWords(on: slot.line, from: slot.line.x0, maxWords: ink.rng.int(1 ... 2), style: style.accent(&ink.rng), density: 1)
            case .body where !headingDone:
                headingDone = true
                writeHeading(on: slot.line)
            case .body, .summary:
                if ink.rng.chance(0.06) {
                    break // blank line between paragraphs
                }
                if listLeft == 0, ink.rng.chance(0.08) {
                    listLeft = ink.rng.int(3 ... 6)
                    dotBullets = ink.rng.chance(0.6)
                }
                var x = slot.line.x0
                if listLeft > 0 {
                    listLeft -= 1
                    x += 1.5 * slot.line.xHeight
                    bullet(at: x - 0.9 * slot.line.xHeight, on: slot.line, dot: dotBullets)
                    x += 0.6 * slot.line.xHeight
                }
                // Paragraph ends leave a short line.
                let end = ink.rng.chance(0.15) ? x + (slot.line.x1 - x) * ink.rng.float(0.3 ... 0.8) : slot.line.x1
                var line = slot.line
                line.x1 = end
                writeWords(on: line, from: x, maxWords: .max, style: style, density: density, highlight: ink.rng.chance(0.1))
            }
            i += 1
        }
        return density
    }

    /// Letter-width factor that makes the page's lines hold about `target` strokes, clamped so sparse
    /// targets leave the page partly empty instead of writing giant words.
    private func fitDensity(_ slots: [Slot], skipping diagram: Range<Int>?) -> Float {
        func capacity(_ density: Float) -> Float {
            var total: Float = diagram == nil ? 0 : 14
            for (i, slot) in slots.enumerated() where diagram?.contains(i) != true {
                switch slot.region {
                case .cue: total += 1.5
                case .body, .summary:
                    // ~0.7: blank lines, paragraph ends, list indents, wrap slack.
                    total += 0.7 * (slot.line.x1 - slot.line.x0) * ink.strokesPerPoint(xHeight: slot.line.xHeight, density: density)
                }
            }
            return total
        }
        var lo = Self.minDensity
        var hi: Float = 1.1
        guard capacity(lo) > Float(target) else { return lo }
        for _ in 0 ..< 12 {
            let mid = (lo + hi) / 2
            if capacity(mid) > Float(target) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    private mutating func writeHeading(on line: TextLine) {
        let heading = style.accent(&ink.rng)
        let end = writeWords(on: line, from: line.x0, maxWords: ink.rng.int(1 ... 4), style: heading, scale: 1.35, density: 1)
        if ink.rng.chance(0.5), !isFull {
            let y = line.baseline(at: line.x0) + 0.45 * line.xHeight
            ink.straight(
                from: (line.x0 - 2, y),
                to: (end + 4, y + ink.rng.float(-1.5 ... 1.5)),
                bow: ink.rng.float(-1 ... 1),
                style: heading
            )
        }
    }

    private mutating func bullet(at x: Float, on line: TextLine, dot: Bool) {
        let y = line.baseline(at: x) - 0.5 * line.xHeight
        if dot {
            ink.dot(at: x, y, radius: 1.2, style: style)
        } else {
            ink.straight(from: (x - 0.4 * line.xHeight, y), to: (x + 0.4 * line.xHeight, y), bow: 0.2, style: style)
        }
    }

    /// Writes words left to right until the line or `maxWords` runs out; returns where the ink ends.
    /// With `highlight`, a run of 2–5 words gets a highlighter swipe afterwards.
    @discardableResult
    private mutating func writeWords(
        on line: TextLine,
        from start: Float,
        maxWords: Int,
        style: InkStyle,
        scale: Float = 1,
        density: Float,
        highlight: Bool = false
    ) -> Float {
        let h = line.xHeight * scale
        let gap = h * ink.hand.wordGap * density.squareRoot()
        var x = start
        var extents: [(Float, Float)] = []
        while extents.count < maxWords, !isFull {
            let letters = Self.letterCounts[ink.rng.weighted(Self.letterWeights)]
            let estimate = Float(letters) * h * ink.hand.letterWidth * density
            guard x + estimate <= line.x1 || extents.isEmpty && estimate < line.x1 - line.x0 else { break }
            let end = ink.word(at: x, on: line, letters: letters, style: style, scale: scale, density: density)
            extents.append((x, end))
            x = end + gap * ink.rng.float(0.8 ... 1.25)
        }
        if highlight, extents.count >= 2, !isFull {
            let first = ink.rng.int(0 ... extents.count - 2)
            let last = min(extents.count - 1, first + ink.rng.int(1 ... 4))
            ink.highlight(from: extents[first].0 - 3, to: extents[last].1 + 3, on: line, style: InkStyle.highlighter(&ink.rng))
        }
        return extents.last?.1 ?? start
    }

    /// Letters per word stroke (English-ish, ~4.4 mean) and their weights.
    private static let letterCounts = [1, 2, 3, 4, 5, 6, 7, 8]
    private static let letterWeights: [Float] = [5, 12, 18, 20, 17, 13, 9, 6]
}

private struct DiagramNode {
    var x: Float
    var y: Float
    var rx: Float
    var ry: Float
}

extension PageComposer {
    // MARK: Layout

    /// Line slots in writing order. Later passes squeeze smaller notes between the earlier lines.
    private mutating func layout(pass: Int) -> [Slot] {
        var rng = SeededRandom(seed: ink.rng.next(), salt: UInt64(pass))
        let hand = ink.hand
        let w = size.width
        let h = size.height
        let shift: Float = pass == 0 ? 0 : (pass % 2 == 1 ? 0.5 : 0.25)
        let shrink: Float = pass == 0 ? 1 : 0.75
        func lines(spacing s: Float, y: ClosedRange<Float>, x: ClosedRange<Float>, ruled: Bool) -> [TextLine] {
            stride(from: y.lowerBound + shift * s, through: y.upperBound, by: s).map { y in
                TextLine(
                    y: y, x0: x.lowerBound, x1: x.upperBound,
                    xHeight: min(12, max(6, 0.38 * s)) * hand.size * shrink,
                    tilt: ruled ? rng.float(-0.003 ... 0.003) : rng.float(-0.02 ... 0.02),
                    drift: rng.noise(),
                    driftAmplitude: ruled ? 0.6 : 2.5
                )
            }
        }
        switch template {
        case let .lined(spacing):
            let s = max(12, spacing)
            return lines(spacing: s, y: 3 * s ... h - 1.5 * s, x: 0.09 * w ... w - 30, ruled: true)
                .map { Slot(line: $0, region: .body) }
        case let .grid(spacing), let .dotted(spacing):
            let s = spacing < 18 ? 1.5 * spacing : spacing
            return lines(spacing: s, y: 3 * s ... h - 1.5 * s, x: 2 * spacing ... w - 1.5 * spacing, ruled: true)
                .map { Slot(line: $0, region: .body) }
        case .blank:
            let s = rng.float(26 ... 34)
            return lines(spacing: s, y: 64 ... h - 40, x: rng.float(36 ... 56) ... w - rng.float(28 ... 44), ruled: false)
                .map { Slot(line: $0, region: .body) }
        case .cornell:
            let s: Float = 24
            let cue = (w * 0.3).rounded()
            let summary = (h * 0.8).rounded()
            var slots: [Slot] = []
            for line in lines(spacing: s, y: 3 * s ... summary - 0.5 * s, x: cue + 10 ... w - 24, ruled: true) {
                if rng.chance(0.22) {
                    var cueLine = line
                    cueLine.x0 = 14
                    cueLine.x1 = cue - 10
                    slots.append(Slot(line: cueLine, region: .cue))
                }
                slots.append(Slot(line: line, region: .body))
            }
            slots += lines(spacing: s, y: summary + 1.5 * s ... h - s, x: 24 ... w - 24, ruled: true)
                .map { Slot(line: $0, region: .summary) }
            return slots
        }
    }

    // MARK: Diagram

    /// 2–3 labelled boxes/ellipses joined by arrows, inside the lines of `slots`.
    private mutating func drawDiagram(in slots: ArraySlice<Slot>) {
        guard let first = slots.first?.line, let last = slots.last?.line else { return }
        let ink2 = ink.rng.chance(0.5) ? style : style.accent(&ink.rng)
        let top = first.y - first.xHeight * 1.5
        let bottom = last.y
        let midY = (top + bottom) / 2
        let count = ink.rng.int(2 ... 3)
        let cell = (first.x1 - first.x0) / Float(count)
        var nodes: [DiagramNode] = []
        for k in 0 ..< count {
            let cx = first.x0 + cell * (Float(k) + 0.5) + ink.rng.float(-10 ... 10)
            let cy = midY + ink.rng.float(-0.18 ... 0.18) * (bottom - top)
            let rx = cell * ink.rng.float(0.25 ... 0.36)
            let ry = (bottom - top) * ink.rng.float(0.16 ... 0.26)
            nodes.append(DiagramNode(x: cx, y: cy, rx: rx, ry: ry))
        }
        for node in nodes where !isFull {
            ink.loop(center: (node.x, node.y), radii: (node.rx, node.ry), squareness: ink.rng.chance(0.6) ? 8 : 2, style: ink2)
            // Label inside the shape.
            var label = first
            label.y = node.y + 0.5 * first.xHeight
            label.tilt = 0
            label.driftAmplitude = 0
            label.x1 = node.x + node.rx * 0.8
            writeWords(on: label, from: node.x - node.rx * 0.65, maxWords: ink.rng.int(1 ... 2), style: style, density: 0.9)
        }
        for (a, b) in zip(nodes, nodes.dropFirst()) where !isFull {
            let from = (a.x + a.rx + 4, a.y)
            let to = (b.x - b.rx - 4, b.y)
            ink.straight(from: from, to: to, bow: ink.rng.float(-6 ... 6), style: ink2)
            if !isFull {
                ink.arrowHead(at: to, direction: atan2(to.1 - from.1, to.0 - from.0), size: ink.rng.float(7 ... 11), style: ink2)
            }
        }
    }
}
