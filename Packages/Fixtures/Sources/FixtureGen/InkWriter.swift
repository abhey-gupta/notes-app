import Foundation
import InkGeometry
import InkModel

/// A ruled (or imagined) line of writing: baseline with slight tilt and drift, x extent, x-height.
struct TextLine {
    var y: Float
    var x0: Float
    var x1: Float
    var xHeight: Float
    var tilt: Float = 0
    var drift = Noise(seed: 0)
    var driftAmplitude: Float = 0

    func baseline(at x: Float) -> Float {
        y + (x - x0) * tilt + driftAmplitude * drift(x / 90)
    }
}

/// Synthesizes strokes for one page, in drawing order, with time-ordered IDs.
///
/// Geometry is smooth by construction (sinusoidal letter strokes, superellipses, bowed lines) plus
/// low-frequency tremor, like real Pencil input after the input pipeline; never a random walk.
struct InkWriter {
    var rng: SeededRandom
    let hand: Hand
    private(set) var strokes: [Stroke] = []
    /// Unix ms of the page's first stroke.
    private let startMilliseconds: UInt64
    /// Seconds since the first stroke (pen-down to pen-down, including pauses).
    private var clock: Float = 0
    private let tremorX: Noise
    private let tremorY: Noise
    private let pressureNoise: Noise
    private let tiltNoise: Noise
    private var xs: [Float] = []
    private var ys: [Float] = []

    init(rng: SeededRandom, hand: Hand, startMilliseconds: UInt64, capacity: Int) {
        self.rng = rng
        self.hand = hand
        self.startMilliseconds = startMilliseconds
        tremorX = self.rng.noise()
        tremorY = self.rng.noise()
        pressureNoise = self.rng.noise()
        tiltNoise = self.rng.noise()
        strokes.reserveCapacity(capacity)
        xs.reserveCapacity(256)
        ys.reserveCapacity(256)
    }

    // MARK: Text

    /// Letter-by-letter plan of one word. Index 0 is the lead-in flick, `n + 1` the exit flick.
    private struct WordPlan {
        /// Per letter: start x, advance, height (x-heights; < 0 descends), loopiness (> 1 loops).
        var starts: [Float]
        var widths: [Float]
        var heights: [Float]
        var loops: [Float]
        /// i-dots (`isDot`) and t-bars drawn after the word, at letter-center x.
        var marks: [(x: Float, isDot: Bool)] = []

        var end: Float {
            starts[starts.count - 1] + 0.3 * widths[widths.count - 1]
        }
    }

    private mutating func planWord(at x: Float, letters n: Int, xHeight h: Float, density: Float) -> WordPlan {
        let zeros = [Float](repeating: 0, count: n + 2)
        var plan = WordPlan(starts: zeros, widths: zeros, heights: zeros, loops: zeros)
        plan.widths[0] = 0.6 * h
        plan.heights[0] = -0.25
        plan.starts[0] = x - plan.widths[0]
        for k in 1 ... n {
            let w = h * hand.letterWidth * density * rng.float(0.75 ... 1.25)
            plan.widths[k] = w
            plan.starts[k] = plan.starts[k - 1] + plan.widths[k - 1]
            switch rng.weighted([60, 18, 12, 10]) {
            case 0: // x-height letter: a cusp or a small loop
                plan.heights[k] = rng.float(0.85 ... 1.1)
                plan.loops[k] = rng.float(0.3 ... 0.8)
                if rng.chance(0.06) {
                    plan.marks.append((plan.starts[k] + 0.5 * w, true))
                }
            case 1: // ascender: tall loop
                plan.heights[k] = rng.float(1.7 ... 2.1)
                plan.loops[k] = rng.float(1.15 ... 1.5)
                if rng.chance(0.25) {
                    plan.marks.append((plan.starts[k] + 0.5 * w, false))
                }
            case 2: // descender: loop below the baseline
                plan.heights[k] = -rng.float(1.0 ... 1.4)
                plan.loops[k] = rng.float(1.1 ... 1.4)
            default: // round letter
                plan.heights[k] = rng.float(0.95 ... 1.1)
                plan.loops[k] = rng.float(0.95 ... 1.1)
            }
        }
        plan.widths[n + 1] = 0.7 * h
        plan.starts[n + 1] = plan.starts[n] + plan.widths[n]
        plan.heights[n + 1] = 0.6
        return plan
    }

    /// Writes one cursive word of `letters` letters starting at `x`; i-dots and t-bars follow as their
    /// own strokes. `scale` sizes headings. Returns the x where the word's ink ends.
    ///
    /// Each letter is one period `f` in `0..<1` of `y = -h·height·(1 - cos 2πf)/2` (up and back to the
    /// baseline) while x advances by the letter width minus `loop·(sin 2πf - sin 4πf / 2)/2π`, which runs
    /// backwards on both flanks when `loop > 1`: a cursive loop. Velocity is horizontal at every letter
    /// boundary, so letters join smoothly.
    @discardableResult
    mutating func word(at x: Float, on line: TextLine, letters: Int, style: InkStyle, scale: Float = 1, density: Float = 1) -> Float {
        let h = line.xHeight * scale
        let n = max(1, letters)
        let plan = planWord(at: x, letters: n, xHeight: h, density: density)
        let perLetter = max(6, hand.samplesPerLetter + rng.int(-2 ... 2))
        let span = Float(n) + 0.55 // tau runs over [-0.25, n + 0.3]
        let count = Int((span * Float(perLetter)).rounded())
        let dt = hand.letterDuration / Float(perLetter) * rng.float(0.9 ... 1.1)
        let phase = rng.float(0 ... 1000)
        xs.removeAll(keepingCapacity: true)
        ys.removeAll(keepingCapacity: true)
        for j in 0 ..< count {
            let tau = -0.25 + span * Float(j) / Float(count - 1)
            let k = min(n + 1, max(0, Int((tau + 1).rounded(.down))))
            let f = tau + 1 - Float(k)
            let angle = 2 * Float.pi * f
            let s1 = sin(angle)
            let c1 = cos(angle)
            let s2 = 2 * s1 * c1
            var lx = plan.starts[k] + plan.widths[k] * (f - plan.loops[k] * (s1 - s2 / 2) / (2 * .pi))
            var ly = -h * plan.heights[k] * (1 - c1) / 2
            lx += 0.05 * h * tremorX(phase + tau * 0.8)
            ly += 0.07 * h * tremorY(phase + tau * 0.8)
            lx -= ly * hand.slant
            xs.append(lx)
            ys.append(line.baseline(at: lx) + ly)
        }
        emit(style: style, dt: dt, pause: rng.float(0.08 ... 0.35))
        for mark in plan.marks {
            let lift: Float = mark.isDot ? 1.8 : 1.4
            let mx = mark.x + hand.slant * lift * h
            let my = line.baseline(at: mark.x) - lift * h
            if mark.isDot {
                dot(at: mx, my, radius: 0.12 * h, style: style)
            } else {
                straight(from: (mx - 0.6 * h, my + 0.1 * h), to: (mx + 0.7 * h, my - 0.1 * h), bow: 0.05 * h, style: style)
            }
        }
        return plan.end
    }

    /// Expected strokes per point of line at x-height `h` and letter-width factor `density`: one word
    /// stroke plus ~0.35 i-dots/t-bars per word (see ``word(at:on:letters:style:scale:density:)``).
    func strokesPerPoint(xHeight h: Float, density: Float) -> Float {
        let advance = h * (4.37 * hand.letterWidth * density + hand.wordGap * density.squareRoot() + 0.21)
        return 1.35 / advance
    }

    // MARK: Marks and shapes

    /// A tapped dot (bullet, i-dot): a tight scribble.
    mutating func dot(at x: Float, _ y: Float, radius: Float, style: InkStyle) {
        let n = rng.int(4 ... 8)
        let start = rng.float(0 ... 6.28)
        trace(count: n, dt: 1 / 120, style: style) { u in
            let a = start + u * 4
            return (x + radius * cos(a) * u, y + radius * sin(a) * u)
        }
    }

    /// A nearly straight hand-drawn line (t-bar, underline, arrow shaft), bowed by `bow` pt.
    mutating func straight(from a: (Float, Float), to b: (Float, Float), bow: Float, style: InkStyle) {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        let length = (dx * dx + dy * dy).squareRoot()
        let nx = -dy / max(length, 0.001)
        let ny = dx / max(length, 0.001)
        let n = min(90, max(8, Int(length / 3.5)))
        // Pencil speeds up mid-line: ease the parameter.
        trace(count: n, dt: 1 / 120, style: style) { u in
            let e = u * u * (3 - 2 * u)
            let off = bow * sin(.pi * e)
            return (a.0 + dx * e + nx * off, a.1 + dy * e + ny * off)
        }
    }

    /// Arrow head at `tip` pointing along `direction` (radians): one V-shaped stroke.
    mutating func arrowHead(at tip: (Float, Float), direction: Float, size: Float, style: InkStyle) {
        let spread: Float = rng.float(0.42 ... 0.6)
        let left = (tip.0 - size * cos(direction - spread), tip.1 - size * sin(direction - spread))
        let right = (tip.0 - size * cos(direction + spread), tip.1 - size * sin(direction + spread))
        trace(count: rng.int(12 ... 18), dt: 1 / 120, style: style) { u in
            let v = u < 0.5 ? u * 2 : (u - 0.5) * 2
            return u < 0.5
                ? (left.0 + (tip.0 - left.0) * v, left.1 + (tip.1 - left.1) * v)
                : (tip.0 + (right.0 - tip.0) * v, tip.1 + (right.1 - tip.1) * v)
        }
    }

    /// Closed rounded shape around `center`: `squareness` 2 is an ellipse, ~6+ a rounded box.
    /// Starts top-left and overshoots its start a little, as people close shapes.
    mutating func loop(center: (Float, Float), radii: (Float, Float), squareness: Float, style: InkStyle) {
        let perimeter = 2 * Float.pi * ((radii.0 * radii.0 + radii.1 * radii.1) / 2).squareRoot()
        let n = min(170, max(40, Int(perimeter / 4.5)))
        let start = -0.75 * Float.pi + rng.float(-0.3 ... 0.3)
        let sweep = 2 * Float.pi + rng.float(0.1 ... 0.35)
        let e = 2 / squareness
        let wobble = rng.noise()
        trace(count: n, dt: 1 / 120, style: style) { u in
            let a = start + sweep * u
            let c = cos(a)
            let s = sin(a)
            let r = 1 + 0.025 * wobble(u * 5)
            return (
                center.0 + r * radii.0 * (c < 0 ? -1 : 1) * pow(abs(c), e),
                center.1 + r * radii.1 * (s < 0 ? -1 : 1) * pow(abs(s), e)
            )
        }
    }

    /// Highlighter swipe along a line of text between `x0` and `x1`.
    mutating func highlight(from x0: Float, to x1: Float, on line: TextLine, style: InkStyle) {
        let n = min(120, max(16, Int((x1 - x0) / 4)))
        let lift = 0.45 * line.xHeight
        let wobble = rng.noise()
        let skew = rng.float(-1 ... 1)
        trace(count: n, dt: 1 / 120, style: style, steadyForce: true) { u in
            let x = x0 + (x1 - x0) * u
            return (x, line.baseline(at: x) - lift + skew * (u - 0.5) + 0.8 * wobble(u * 3))
        }
    }

    // MARK: Emitting

    /// Samples `path(u)` for `u` in `0...1` into ``xs``/``ys`` (with tremor) and emits the stroke.
    private mutating func trace(
        count: Int,
        dt: Float,
        style: InkStyle,
        steadyForce: Bool = false,
        _ path: (Float) -> (Float, Float)
    ) {
        xs.removeAll(keepingCapacity: true)
        ys.removeAll(keepingCapacity: true)
        let phase = rng.float(0 ... 1000)
        let denominator = Float(max(1, count - 1))
        for j in 0 ..< count {
            let u = Float(j) / denominator
            let p = path(u)
            xs.append(p.0 + 0.15 * tremorX(phase + u * 2))
            ys.append(p.1 + 0.15 * tremorY(phase + u * 2))
        }
        emit(style: style, dt: dt * rng.float(0.85 ... 1.15), pause: rng.float(0.15 ... 0.6), steadyForce: steadyForce)
    }

    /// Turns ``xs``/``ys`` into samples (force from speed and pen-down/up envelope, tilt drift),
    /// appends the stroke, and advances the clock by its duration plus `pause`.
    private mutating func emit(style: InkStyle, dt: Float, pause: Float, steadyForce: Bool = false) {
        let n = xs.count
        guard n > 0 else { return }
        var total: Float = 0
        for j in 1 ..< max(1, n) {
            total += hypot(xs[j] - xs[j - 1], ys[j] - ys[j - 1])
        }
        let meanStep = max(total / Float(max(1, n - 1)), 0.001)
        let base = hand.pressure * rng.float(0.85 ... 1.15)
        let phase = rng.float(0 ... 1000)
        var samples: [Sample] = []
        samples.reserveCapacity(n)
        for j in 0 ..< n {
            let t = Float(j) * dt
            let force: Float
            if steadyForce {
                force = 0.5 + 0.04 * pressureNoise(phase + t * 3)
            } else {
                let envelope = min(1, Float(j + 1) / 4) * min(1, Float(n - j) / 5)
                let step = j == 0 ? meanStep : hypot(xs[j] - xs[j - 1], ys[j] - ys[j - 1])
                let slow = 1 - min(step / meanStep, 2) // +1 when stopped, -1 at double speed
                force = base * (0.35 + 0.65 * envelope) * (1 + 0.2 * slow) + 0.04 * pressureNoise(phase + t * 6)
            }
            samples.append(Sample(
                x: xs[j],
                y: ys[j],
                force: min(1, max(0.02, force)),
                altitude: hand.altitude + 0.06 * tiltNoise(phase + t * 2),
                azimuth: hand.azimuth + 0.1 * tiltNoise(phase + 500 + t * 2),
                t: t
            ))
        }
        let milliseconds = startMilliseconds + UInt64(clock * 1000)
        let id = StrokeID(uuid: UUIDv7.make(
            milliseconds: milliseconds,
            randA: UInt16(truncatingIfNeeded: strokes.count),
            randB: rng.next()
        ))
        // Format v2: PencilKit rendering data as the app draws it (point sizes from the pen profile).
        let plain = Stroke(id: id, tool: style.tool, color: style.color, width: style.width, samples: samples)
        strokes.append(Stroke(
            id: id, tool: style.tool, color: style.color, width: style.width, samples: samples, rendering: plain.derivedRendering
        ))
        clock += Float(n) * dt + pause
    }
}
